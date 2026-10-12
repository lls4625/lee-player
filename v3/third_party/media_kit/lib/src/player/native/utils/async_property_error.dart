/// Errors for LeePlayer's additive, asynchronous property-read API.
/// The upstream synchronous API is unchanged. See LOCAL_PATCH.md.
class MpvPropertyReadException implements Exception {
  const MpvPropertyReadException(this.property, this.errorCode,
      {this.submission = false});

  final String property;
  final int errorCode;
  final bool submission;

  @override
  String toString() => 'MpvPropertyReadException($property, $errorCode, '
      '${submission ? "submission" : "reply"})';
}

/// The request was NOT submitted. Native requests which time out still retain
/// their slots until their replies arrive or this reader is closed.
class MpvPropertyReadBusy implements Exception {
  const MpvPropertyReadBusy(this.controlRead);
  final bool controlRead;

  @override
  String toString() => 'MpvPropertyReadBusy(controlRead: $controlRead)';
}
