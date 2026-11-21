package com.example.velora

import android.app.Activity
import android.app.Instrumentation
import android.content.Context
import android.content.ContextWrapper
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteException
import android.os.Bundle
import android.os.Process
import android.util.Base64
import org.json.JSONObject
import java.io.File
import java.lang.reflect.InvocationTargetException

/** Test APK only. Fixtures stay under a unique directory in target no-backup storage. */
class AndroidSqliteJournalInstrumentation : Instrumentation() {
    private var options = Bundle()

    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        options = arguments ?: Bundle()
        start()
    }

    override fun onStart() {
        val result = Bundle()
        try {
            val phase = options.getString("phase") ?: "suite"
            require(phase in setOf("suite", "prepare", "recover"))
            val runId = options.getString("runId") ?: error("Supply a unique runId")
            require(Regex("[A-Za-z0-9_-]{1,64}").matches(runId))
            val directory = File(targetContext.noBackupFilesDir, "velora-sqlite-qualification/$runId")
            when (phase) {
                "suite" -> {
                    check(directory.mkdirs()) { "Use a fresh runId for suite" }
                    runSuite(directory)
                }
                "prepare" -> {
                    check(directory.mkdirs()) { "Use a fresh runId for prepare" }
                    val db = fixture(directory)
                    check(db.commit(0, journalWrites(1, "prepared")) == 1L)
                    check(db.commit(1, journalWrites(2, "dispatched")) == 2L)
                    File(directory, "prepare-pid").writeText(Process.myPid().toString())
                }
                "recover" -> {
                    check(directory.isDirectory) { "Matching prepare fixture is missing" }
                    val previousPid = File(directory, "prepare-pid").readText().toInt()
                    check(previousPid != Process.myPid()) { "Recovery must run in a fresh process" }
                    val db = fixture(directory)
                    val expected = journalWrites(1, "prepared") + journalWrites(2, "dispatched")
                    val recovered = db.snapshot()
                    check(recovered == Snapshot(2, expected))
                    val request = JSONObject(recovered.rows.getValue(head)).getJSONObject("payload")
                        .getJSONObject("request")
                    check(request.getString("idempotencyKey") == stableKey)
                    check(db.snapshot() == recovered) { "Recovery read changed stored evidence" }
                    check(!db.file.readBytes().toString(Charsets.UTF_8).contains(bearerSentinel))
                    result.putInt("preparedPid", previousPid)
                }
            }
            result.putInt("pid", Process.myPid())
            result.putString("stream", "VELORA SQLITE PASS phase=$phase\n")
            finish(Activity.RESULT_OK, result)
        } catch (error: Exception) {
            result.putString("stream", "VELORA SQLITE FAIL ${error.javaClass.simpleName}: ${error.message}\n")
            finish(Activity.RESULT_CANCELED, result)
        }
    }

    private fun runSuite(directory: File) {
        val db = fixture(child(directory, "transactions"))
        val initialWrites = journalWrites(1, "prepared")
        check(db.snapshot() == Snapshot(0, emptyMap()))
        check(!File(directory, db.file.name).exists())
        check(db.commit(0, initialWrites) == 1L)
        check(db.snapshot() == Snapshot(1, initialWrites))
        check(db.file.isFile)

        // Fail the head INSERT after the history INSERT in the real transaction.
        // A second connection supplies the failure without changing the store.
        SQLiteDatabase.openDatabase(db.file.path, null, SQLiteDatabase.OPEN_READWRITE).use { sqlite ->
            sqlite.execSQL(
                "CREATE TRIGGER reject_head BEFORE INSERT ON journal " +
                    "WHEN NEW.address = '$head' BEGIN SELECT RAISE(ABORT, 'fixture rollback'); END",
            )
        }
        val failure = rejected { db.commit(1, journalWrites(2, "dispatched")) }
        check(failure is SQLiteException && failure.message.orEmpty().contains("fixture rollback"))
        check(db.snapshot() == Snapshot(1, initialWrites))
        SQLiteDatabase.openDatabase(db.file.path, null, SQLiteDatabase.OPEN_READWRITE).use { sqlite ->
            sqlite.execSQL("DROP TRIGGER reject_head")
        }

        val nextWrites = journalWrites(2, "dispatched")
        check(db.commit(1, nextWrites) == 2L)
        rejected { db.commit(1, journalWrites(2, "unknown")) }
        val reopened = fixture(db.file.parentFile!!)
        check(reopened.snapshot() == Snapshot(2, initialWrites + nextWrites))
        check(reopened.snapshot(cafe = "other-cafe") == Snapshot(0, emptyMap()))
        check(reopened.snapshot(uid = "other-user") == Snapshot(0, emptyMap()))
        rejected { reopened.commit(0, initialWrites, uid = "other-user") }
        rejected { reopened.snapshot(project = "velora-73222") }
        check(!db.file.readBytes().toString(Charsets.UTF_8).contains(bearerSentinel))

        SQLiteDatabase.openDatabase(db.file.path, null, SQLiteDatabase.OPEN_READWRITE).use { sqlite ->
            sqlite.version = 2
        }
        rejected { reopened.snapshot() }
        SQLiteDatabase.openDatabase(db.file.path, null, SQLiteDatabase.OPEN_READONLY).use { sqlite ->
            check(sqlite.version == 2)
            sqlite.rawQuery("SELECT COUNT(*) FROM journal", null).use { cursor ->
                check(cursor.moveToFirst() && cursor.getInt(0) == 3)
            }
        }

        val corrupt = fixture(child(directory, "corrupt"))
        val corruptBytes = ByteArray(512) { 42 }
        corrupt.file.writeBytes(corruptBytes)
        rejected { corrupt.snapshot() }
        check(corrupt.file.readBytes().contentEquals(corruptBytes))

        val incomplete = fixture(child(directory, "incomplete"))
        check(incomplete.commit(0, initialWrites) == 1L)
        SQLiteDatabase.openDatabase(incomplete.file.path, null, SQLiteDatabase.OPEN_READWRITE).use { sqlite ->
            check(sqlite.delete("journal", null, null) == 2)
        }
        rejected { incomplete.snapshot() }
    }

    private fun child(parent: File, name: String) = File(parent, name).also {
        check(it.mkdir())
    }

    private fun fixture(directory: File): StoreFixture {
        val context = object : ContextWrapper(targetContext) {
            override fun getNoBackupFilesDir(): File = directory
        }
        return StoreFixture(context, directory)
    }
}

private const val testProject = "velora-spark-test"
private const val testUid = "synthetic-owner"
private const val testCafe = "synthetic-cafe"
private const val stableKey = "synthetic-inventory-request-0001"
private const val bearerSentinel = "Authorization: Bearer synthetic-sqlite-test-only"
private fun segment(value: String) = Base64.encodeToString(
    value.toByteArray(Charsets.UTF_8), Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP,
)

private val namespace get() = "journal/1/${segment(testProject)}/${segment(testUid)}"
private val address get() = "mutation/${segment("fixture-$stableKey")}"
private val head get() = "$namespace/records/$address"

private fun journalWrites(sequence: Int, state: String): Map<String, String> {
    // The native store treats these as opaque strings. Dart owns envelope validation.
    val record = JSONObject().apply {
        put("sequence", sequence)
        put("payload", JSONObject().put("state", state).put("request", JSONObject()
            .put("idempotencyKey", stableKey).put("expectedCafeId", testCafe)))
    }.toString()
    val history = "$namespace/history/$address/${sequence.toString().padStart(16, '0')}"
    return linkedMapOf(history to record, head to record)
}

private fun rejected(action: () -> Unit): Exception {
    try {
        action()
    } catch (failure: Exception) {
        return failure
    }
    error("Expected native store rejection")
}

private data class Snapshot(val revision: Long, val rows: Map<String, String>)

// Android test invokes the actual private store without exposing production APIs.
private class StoreFixture(context: Context, directory: File) {
    val file = File(directory, "inventory-journal-v1.sqlite")
    private val type = Class.forName("com.example.velora.AndroidJournalStore", true, context.classLoader)
    private val store = type.getDeclaredConstructor(Context::class.java).apply {
        isAccessible = true
    }.newInstance(context)

    private fun invoke(method: String, args: Map<String, Any>): Any =
        try {
            type.getDeclaredMethod(method, Map::class.java).apply {
                isAccessible = true
            }.invoke(store, args)!!
        } catch (failure: InvocationTargetException) {
            throw failure.targetException
        }

    private fun scope(uid: String, cafe: String, project: String = testProject) =
        mapOf("projectId" to project, "uid" to uid, "cafeId" to cafe)

    fun snapshot(uid: String = testUid, cafe: String = testCafe, project: String = testProject): Snapshot {
        val result = invoke("snapshot", scope(uid, cafe, project)) as Map<*, *>
        val rows = result["rows"] as Map<*, *>
        return Snapshot(result["revision"] as Long,
            rows.entries.associate { (key, value) -> key as String to value as String })
    }

    fun commit(revision: Long, writes: Map<String, String>, uid: String = testUid): Long =
        invoke("commit", scope(uid, testCafe) + mapOf("revision" to revision, "writes" to writes)) as Long
}
