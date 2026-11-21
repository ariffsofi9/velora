package com.example.velora.journaldiagnostic

import com.example.velora.AndroidSqliteJournalPlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class JournalDiagnosticActivity : FlutterActivity() {
    override fun configureFlutterEngine(engine: FlutterEngine) {
        engine.plugins.add(AndroidSqliteJournalPlugin())
        MethodChannel(engine.dartExecutor.binaryMessenger, "velora/journal_diagnostic")
            .setMethodCallHandler { call, result ->
                if (call.method == "receiptDirectory") {
                    result.success(noBackupFilesDir.absolutePath)
                } else {
                    result.notImplemented()
                }
            }
    }
}
