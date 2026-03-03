class WitrData {
  final ProcessData process;
  final SourceData source;

  WitrData({required this.process, required this.source});

  factory WitrData.fromJson(Map<String, dynamic> json) {
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

    return WitrData(
      process: ProcessData.fromJson(processJson),
      source: SourceData.fromJson(sourceJson),
    );
  }
}

class SourceData {
  final String type;

  SourceData({required this.type});

  factory SourceData.fromJson(Map<String, dynamic> json) =>
      SourceData(type: json['Type'] as String? ?? '<unknown>');
}

class ProcessData {
  final String cmdline;
  final List<String>? env;

  ProcessData({required this.cmdline, this.env});

  factory ProcessData.fromJson(Map<String, dynamic> json) => ProcessData(
    cmdline: json['Cmdline'] as String? ?? '<unknown>',
    env: (json['Env'] as List<dynamic>? ?? []).map((e) => e as String).toList(),
  );
}
