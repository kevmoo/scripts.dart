class WitrData {
  final ProcessData process;
  final int restartCount;
  final List<ProcessData> ancestry;
  final SourceData source;
  final List<String> warnings;

  WitrData({
    required this.process,
    required this.restartCount,
    required this.ancestry,
    required this.source,
    required this.warnings,
  });

  factory WitrData.fromJson(Map<String, dynamic> json) {
    final processJson = switch (json['Process']) {
      final Map<String, dynamic> v => v,
      _ => throw const FormatException(
        '`Process` field is missing or not a map.',
      ),
    };

    final restartCount = switch (json['RestartCount']) {
      final int v => v,
      _ => throw const FormatException(
        '`RestartCount` field is missing or not an int.',
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
      restartCount: restartCount,
      ancestry: (json['Ancestry'] as List<dynamic>? ?? [])
          .map((e) => ProcessData.fromJson(e as Map<String, dynamic>))
          .toList(),
      source: SourceData.fromJson(sourceJson),
      warnings: (json['Warnings'] as List<dynamic>? ?? [])
          .map((e) => e as String)
          .toList(),
    );
  }
}

class SourceData {
  final String type;
  final String name;

  SourceData({required this.type, required this.name});

  factory SourceData.fromJson(Map<String, dynamic> json) => SourceData(
    type: json['Type'] as String? ?? '<unknown>',
    name: json['Name'] as String? ?? '<unknown>',
  );
}

class ProcessData {
  final int pid;
  final String command;
  final String cmdline;
  final String user;
  final String workingDir;
  final List<int> listeningPorts;
  final List<String> bindAddresses;
  final List<String>? env;

  ProcessData({
    required this.pid,
    required this.command,
    required this.cmdline,
    required this.user,
    required this.workingDir,
    required this.listeningPorts,
    required this.bindAddresses,
    this.env,
  });

  factory ProcessData.fromJson(Map<String, dynamic> json) => ProcessData(
    pid: json['PID'] as int,
    command: json['Command'] as String? ?? '<unknown>',
    cmdline: json['Cmdline'] as String? ?? '<unknown>',
    user: json['User'] as String? ?? '<unknown>',
    workingDir: json['WorkingDir'] as String? ?? '<unknown>',
    listeningPorts: (json['ListeningPorts'] as List<dynamic>? ?? [])
        .map((e) => e as int)
        .toList(),
    bindAddresses: (json['BindAddresses'] as List<dynamic>? ?? [])
        .map((e) => e as String)
        .toList(),
    env: (json['Env'] as List<dynamic>? ?? []).map((e) => e as String).toList(),
  );
}
