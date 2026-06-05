class WitrData({
  required final ProcessData process,
  required final SourceData source,
}) {
  factory fromJson(Map<String, dynamic> json) {
    final processJson = switch (json['Process']) {
      final Map<String, dynamic> v => v,
      _ => throw const FormatException(
        '`Process` field is missing or not a map.',
      ),
    };

    final sourceJson = switch (json['Source']) {
      final Map<String, dynamic> v => v,
      _ => throw const FormatException(
        '`Source` field is missing or not a map.',
      ),
    };

    return .new(
      process: ProcessData.fromJson(processJson),
      source: SourceData.fromJson(sourceJson),
    );
  }
}

class SourceData({required final String type}) {
  factory fromJson(Map<String, dynamic> json) =>
      .new(type: json['Type'] as String? ?? '<unknown>');
}

class ProcessData({
  required final String cmdline,
  final List<String>? env,
  final int? ppid,
}) {
  factory fromJson(Map<String, dynamic> json) => .new(
    cmdline: json['Cmdline'] as String? ?? '<unknown>',
    env: (json['Env'] as List<dynamic>? ?? []).map((e) => e as String).toList(),
    ppid: json['PPID'] as int?,
  );
}
