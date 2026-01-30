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
    return WitrData(
      process: ProcessData.fromJson(json['Process'] as Map<String, dynamic>),
      restartCount: json['RestartCount'] as int,
      ancestry: (json['Ancestry'] as List<dynamic>? ?? [])
          .map((e) => ProcessData.fromJson(e as Map<String, dynamic>))
          .toList(),
      source: SourceData.fromJson(json['Source'] as Map<String, dynamic>),
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

  factory SourceData.fromJson(Map<String, dynamic> json) {
    return SourceData(
      type: json['Type'] as String? ?? '<unknown>',
      name: json['Name'] as String? ?? '<unknown>',
    );
  }
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

  factory ProcessData.fromJson(Map<String, dynamic> json) {
    return ProcessData(
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
      env: (json['Env'] as List<dynamic>? ?? [])
          .map((e) => e as String)
          .toList(),
    );
  }
}
