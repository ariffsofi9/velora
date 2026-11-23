package com.example.velora

import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.DatabaseErrorHandler
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteDatabaseCorruptException
import android.os.Handler
import android.os.Looper
import android.util.Base64
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors

/** Private platform channel for the app-local inventory journal. */
class AndroidSqliteJournalPlugin : FlutterPlugin {
    private var channel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val store = AndroidJournalStore(binding.applicationContext)
        val executor = Executors.newSingleThreadExecutor()
        val main = Handler(Looper.getMainLooper())
        channel = MethodChannel(binding.binaryMessenger, "velora/android_sqlite_journal").apply {
            setMethodCallHandler { call, result ->
                if (call.method !in setOf("snapshot", "commit", "sha256")) {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                executor.execute {
                    try {
                        val value = when (call.method) {
                            "snapshot" -> store.snapshot(call.arguments as Map<*, *>)
                            "commit" -> store.commit(call.arguments as Map<*, *>)
                            else -> {
                                val value = call.arguments as String
                                require(value.length <= 16384)
                                val input = value.toByteArray(Charsets.UTF_8)
                                require(input.size <= 16384)
                                MessageDigest.getInstance("SHA-256").digest(input)
                                    .joinToString("") { "%02x".format(it.toInt() and 255) }
                            }
                        }
                        main.post { result.success(value) }
                    } catch (_: Exception) {
                        main.post { result.error("unavailable", "Journal storage unavailable.", null) }
                    }
                }
            }
        }
        closeExecutor = { executor.shutdown() }
    }

    private var closeExecutor: (() -> Unit)? = null

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        closeExecutor?.invoke()
        closeExecutor = null
    }
}

// Schema v1: partitions are keyed by project, UID and café. Each revision
// covers a complete set of journal keys. PlatformJournalStore owns head/history
// semantics. Future schema changes require an explicit migration, never a reset.
private class AndroidJournalStore(context: Context) {
    private val database = File(context.noBackupFilesDir, "inventory-journal-v1.sqlite")

    private companion object {
        val initialization = Any()
        val projects = setOf("velora-spark-test", "velora-73222")
        const val version = 1
        const val maxRecords = 512
        const val maxBytes = 2 * 1024 * 1024
        const val maxRevision = 9007199254740991L
        val asciiKey = Regex("[!-~]+")
        val noDelete = DatabaseErrorHandler { throw SQLiteDatabaseCorruptException("Journal is corrupt") }
    }

    private data class Scope(val id: String, val prefix: String)

    private fun segment(value: String) = Base64.encodeToString(
        value.toByteArray(Charsets.UTF_8),
        Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING,
    )

    private fun scope(args: Map<*, *>): Scope {
        fun identifier(name: String): String {
            val value = args[name] as? String ?: error("Invalid scope")
            require(value.isNotBlank() && value.length <= 128 && value.trim() == value &&
                value != "." && value != ".." &&
                value.none { it == '/' || it == '\\' || it.isISOControl() } &&
                value.toByteArray(Charsets.UTF_8).toString(Charsets.UTF_8) == value)
            return segment(value)
        }
        val project = args["projectId"] as? String ?: error("Invalid project")
        require(project in projects)
        val projectKey = segment(project)
        val uid = identifier("uid")
        return Scope("$projectKey/$uid/${identifier("cafeId")}", "journal/1/$projectKey/$uid/")
    }

    private fun validate(scope: Scope, key: String, value: String) {
        require(key.length <= 4096 && key.startsWith(scope.prefix) && asciiKey.matches(key))
        require(value.length in 1..16384 && value.toByteArray(Charsets.UTF_8).size <= 16384)
    }

    private fun <T> inTransaction(db: SQLiteDatabase, action: () -> T): T {
        db.beginTransaction()
        try {
            val result = action()
            db.setTransactionSuccessful()
            return result
        } finally {
            // A MethodChannel acknowledgement is sent only after this succeeds.
            db.endTransaction()
        }
    }

    private fun open(): SQLiteDatabase = synchronized(initialization) {
        val existed = database.exists()
        val db = SQLiteDatabase.openDatabase(
            database.path, null,
            SQLiteDatabase.OPEN_READWRITE or (if (existed) 0 else SQLiteDatabase.CREATE_IF_NECESSARY),
            noDelete,
        )
        try {
            // Android connection settings back this connection's PRAGMA checks.
            db.disableWriteAheadLogging()
            db.setForeignKeyConstraintsEnabled(true)
            db.rawQuery("PRAGMA journal_mode = DELETE", null).use { cursor ->
                check(cursor.moveToFirst() && cursor.getString(0) == "delete")
            }
            db.execSQL("PRAGMA synchronous = FULL")
            db.rawQuery("PRAGMA synchronous", null).use { cursor ->
                check(cursor.moveToFirst() && cursor.getInt(0) >= 2)
            }
            db.rawQuery("PRAGMA quick_check(1)", null).use { cursor ->
                check(cursor.moveToFirst() && cursor.getString(0) == "ok" && !cursor.moveToNext())
            }
            inTransaction(db) {
                if (!existed && db.version == 0) {
                    db.execSQL("CREATE TABLE partition (scope TEXT PRIMARY KEY NOT NULL, revision INTEGER NOT NULL CHECK (revision > 0))")
                    db.execSQL("CREATE TABLE journal (scope TEXT NOT NULL REFERENCES partition(scope), address TEXT NOT NULL, record TEXT NOT NULL, PRIMARY KEY (scope, address))")
                    db.version = version
                }
                check(db.version == version)
            }
            db
        } catch (error: Exception) {
            db.close()
            throw error
        }
    }

    private fun SQLiteDatabase.revision(scope: Scope): Long =
        rawQuery("SELECT revision FROM partition WHERE scope = ?", arrayOf(scope.id)).use { cursor ->
            if (!cursor.moveToFirst()) return@use 0L
            check(cursor.getType(0) == Cursor.FIELD_TYPE_INTEGER)
            cursor.getLong(0).also { check(it in 1..maxRevision && !cursor.moveToNext()) }
        }

    private fun SQLiteDatabase.rowCount(scope: Scope, revision: Long): Int = rawQuery(
        "SELECT COUNT(*), COALESCE(SUM(length(address) + length(CAST(record AS BLOB))), 0) FROM journal WHERE scope = ?",
        arrayOf(scope.id),
    ).use { cursor ->
        check(cursor.moveToFirst())
        val count = cursor.getLong(0)
        check(count in 0..maxRecords.toLong() && cursor.getLong(1) in 0..maxBytes.toLong())
        check((revision == 0L) == (count == 0L))
        count.toInt()
    }

    fun snapshot(args: Map<*, *>): Map<String, Any> {
        val scope = scope(args)
        return open().use { db ->
            inTransaction(db) {
                val revision = db.revision(scope)
                val count = db.rowCount(scope, revision)
                val rows = LinkedHashMap<String, String>(count)
                db.rawQuery("SELECT address, record FROM journal WHERE scope = ? ORDER BY address", arrayOf(scope.id))
                    .use { cursor ->
                        while (cursor.moveToNext()) {
                            val key = cursor.getString(0)
                            val value = cursor.getString(1)
                            validate(scope, key, value)
                            check(rows.put(key, value) == null)
                        }
                    }
                check(rows.size == count)
                mapOf("revision" to revision, "rows" to rows)
            }
        }
    }

    fun commit(args: Map<*, *>): Long {
        val scope = scope(args)
        val expected = when (val raw = args["revision"]) {
            is Int -> raw.toLong()
            is Long -> raw
            else -> error("Invalid revision")
        }
        require(expected in 0 until maxRevision)
        val input = args["writes"] as? Map<*, *> ?: error("Invalid writes")
        require(input.size in 1..maxRecords)
        val writes = input.entries.associate { (k, v) ->
            val key = k as? String ?: error("Invalid address")
            val value = v as? String ?: error("Invalid record")
            validate(scope, key, value)
            key to value
        }
        require(writes.entries.sumOf { (k, v) -> k.length + v.toByteArray(Charsets.UTF_8).size } <= maxBytes)
        return open().use { db ->
            inTransaction(db) {
                check(db.revision(scope) == expected)
                db.rowCount(scope, expected)
                val next = expected + 1
                val revision = ContentValues().apply { put("revision", next) }
                if (expected == 0L) {
                    revision.put("scope", scope.id)
                    db.insertOrThrow("partition", null, revision)
                } else {
                    check(db.update("partition", revision, "scope = ?", arrayOf(scope.id)) == 1)
                }
                for ((key, value) in writes) {
                    val row = ContentValues().apply {
                        put("scope", scope.id)
                        put("address", key)
                        put("record", value)
                    }
                    check(db.insertWithOnConflict("journal", null, row, SQLiteDatabase.CONFLICT_REPLACE) != -1L)
                }
                db.rowCount(scope, next)
                next
            }
        }
    }
}
