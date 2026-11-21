package com.example.velora.journalqualification

import com.example.velora.AndroidSqliteJournalPlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class JournalQualificationActivity : FlutterActivity() {
    override fun configureFlutterEngine(engine: FlutterEngine) {
        engine.plugins.add(AndroidSqliteJournalPlugin())
        MethodChannel(engine.dartExecutor.binaryMessenger, "velora/journal_qualification")
            .setMethodCallHandler { call, result ->
                if (call.method == "receiptDirectory") {
                    result.success(noBackupFilesDir.absolutePath)
                } else {
                    result.notImplemented()
                }
            }
    }
}
