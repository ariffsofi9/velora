import 'package:firebase_core/firebase_core.dart';

/// Verified separate Spark Web app, 2026-11-07. No production fallback.
/// Auth setup remains incomplete; no acceptance tests authorized.
class SparkTestFirebaseOptions {
  static const projectId = 'velora-spark-test';
  static const web = FirebaseOptions(
    apiKey: "AIzaSyCn5jp8Nac5Z8aVJt1s8QUj_tzrYrnsJng",
    appId: "1:91746034332:web:e3fd425f164a7721408359",
    messagingSenderId: "91746034332",
    projectId: "velora-spark-test",
    authDomain: "velora-spark-test.firebaseapp.com",
    storageBucket: "velora-spark-test.firebasestorage.app",
  );
}
