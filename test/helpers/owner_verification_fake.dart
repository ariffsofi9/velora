import 'package:velora/services/owner_email_verification.dart';

class VerifiedOwnerFake implements OwnerEmailVerification {
  final String? Function() uid;
  bool verified;
  int refreshes = 0;
  VerifiedOwnerFake({String? Function()? uid, this.verified = true})
    : uid = uid ?? (() => 'owner');
  @override
  String? get currentUid => uid();
  @override
  Duration get resendRemaining => Duration.zero;
  @override
  Future<bool> refreshVerified() async {
    refreshes++;
    return verified;
  }

  @override
  Future<void> sendVerification() async {}
  @override
  Future<void> signOut() async {}
}
