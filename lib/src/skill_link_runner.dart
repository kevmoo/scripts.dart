import 'dart:io';

import 'package:build_cli_annotations/build_cli_annotations.dart';
import 'package:io/io.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

part 'skill_link_runner.g.dart';

const _homeConfigDir = '.config';
const _configFileName = 'com.kevmoo.skills.yaml';
final documentedConfigLocation = p.join('~', _homeConfigDir, _configFileName);

Future<int> runSkillLink({String? configPath, String? defaultHomeDir}) async {
  final homeDir =
      defaultHomeDir ??
      Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'];
  if (homeDir == null) {
    print('Error: HOME environment variable is not set.');
    return ExitCode.software.code;
  }

  final resolvedConfigPath =
      configPath ?? p.join(homeDir, _homeConfigDir, _configFileName);

  final configFile = File(resolvedConfigPath);
  if (!configFile.existsSync()) {
    print('Configuration file not found at: $resolvedConfigPath\n');
    print('Expected format:');
    print('''
sources:
  - /path/to/source1
  - /path/to/source2
targets:
  - /path/to/target1
''');
    return ExitCode.config.code;
  }

  final yamlString = configFile.readAsStringSync();
  final YamlMap yamlDoc;
  try {
    yamlDoc = loadYaml(yamlString) as YamlMap;
  } catch (e) {
    print('Error parsing YAML from $resolvedConfigPath:');
    print(e);
    return ExitCode.config.code;
  }

  final sourcesNode = yamlDoc['sources'] as YamlList?;
  final targetsNode = yamlDoc['targets'] as YamlList?;

  if (sourcesNode == null || targetsNode == null) {
    print('Error: Configuration must contain "sources" and "targets" lists.');
    return ExitCode.config.code;
  }

  final sources = sourcesNode.cast<String>().toList();
  final targets = targetsNode.cast<String>().toList();

  for (final target in targets) {
    final targetDir = Directory(target);
    if (!targetDir.existsSync()) {
      print('Target directory does not exist: $target');
      return ExitCode.config.code;
    }
  }

  // Mapping of expected skills: basename -> absolute expected path
  final expectedSkills = <String, String>{};
  final skillsBySource = <String, List<String>>{};

  for (final source in sources) {
    final sourceDir = Directory(source);
    if (!sourceDir.existsSync()) {
      print('Warning: Source directory does not exist: $source');
      continue;
    }

    final sourceSkills = <String>[];

    // Agent skills spec implies directories live under .agent
    final agentDir = Directory(p.join(source, '.agent'));
    if (agentDir.existsSync()) {
      final entities = agentDir.listSync(recursive: true);
      for (final entity in entities) {
        if (entity is File && p.basename(entity.path) == 'SKILL.md') {
          final skillDir = entity.parent.path;
          final skillName = p.basename(skillDir);

          if (expectedSkills.containsKey(skillName)) {
            sourceSkills.add(
              '$skillName -> WILL BE IGNORED. Duplicate skill name.',
            );
          } else {
            expectedSkills[skillName] = skillDir;
            sourceSkills.add(skillName);
          }
        }
      }
    }

    if (sourceSkills.isNotEmpty) {
      skillsBySource[source] = sourceSkills;
    }
  }

  if (skillsBySource.isEmpty) {
    print('Warning: No skill directories were found in the provided sources.');
  } else {
    print('Found skill directories:');
    for (final entry in skillsBySource.entries) {
      print('  ${entry.key}:');
      for (final skillName in entry.value) {
        print('    - $skillName');
      }
    }
  }

  print('\nProcessing targets:');
  for (final target in targets) {
    final targetDir = Directory(target);

    // Determine existing symlinks inside target directory
    final existingLinks = targetDir
        .listSync(followLinks: false)
        .whereType<Link>()
        .toList();

    // Clone expected skills so we can mutate it per target
    final missingSkills = Map<String, String>.from(expectedSkills);
    final targetOutput = <String>[];

    for (final link in existingLinks) {
      final linkName = p.basename(link.path);
      final rawTarget = link.targetSync();
      final linkTarget = p.isAbsolute(rawTarget)
          ? p.normalize(rawTarget)
          : p.normalize(p.join(targetDir.path, rawTarget));

      final isExpected =
          missingSkills.containsKey(linkName) &&
          missingSkills[linkName] == linkTarget;

      if (isExpected) {
        targetOutput.add('    $linkName: symlink exists and is correct');
        // Remove from expected map so we don\'t try to create it again
        missingSkills.remove(linkName);
      } else {
        // Evaluate if linkTarget points to a non-existent directory
        if (!Directory(linkTarget).existsSync()) {
          // Check if linkTarget is a child of one of the defined sources
          var isChildOfSource = false;
          for (final source in sources) {
            if (p.isWithin(source, linkTarget)) {
              isChildOfSource = true;
              break;
            }
          }

          if (isChildOfSource) {
            targetOutput.add('    $linkName: Removed broken symlink');
            link.deleteSync();
          } else {
            targetOutput.add(
              '    $linkName: Warning! Symlink points to a non-existent '
              'directory that is NOT a child of configured sources.',
            );
          }
        } else {
          // Symlink points to an existing directory, but is unexpected.
          targetOutput.add(
            '    $linkName: Warning! Unexpected symlink points to an '
            'existing directory: $linkTarget',
          );
        }
      }
    }

    // Now create any missing symlinks
    for (final entry in missingSkills.entries) {
      final linkPath = p.join(target, entry.key);
      final link = Link(linkPath);

      // If there is already something there (e.g. a directory, or an unexpected
      // symlink that pointed to an existing place), we shouldn't just blindly
      // create. We should check if it exists.
      final isNotFound =
          FileSystemEntity.typeSync(linkPath, followLinks: false) ==
          FileSystemEntityType.notFound;
      if (isNotFound) {
        try {
          link.createSync(entry.value);
          targetOutput.add('    ${entry.key}: Created symlink');
        } catch (e) {
          targetOutput.add('    ${entry.key}: Failed to create symlink ($e)');
        }
      } else {
        targetOutput.add(
          '    ${entry.key}: Warning! Cannot create symlink at $linkPath '
          'because a file or directory already exists there.',
        );
      }
    }

    if (targetOutput.isNotEmpty) {
      print('  $target:');
      targetOutput.sort();
      for (final line in targetOutput) {
        print(line);
      }
    }
  }
  print('Done.');
  return ExitCode.success.code;
}

@CliOptions()
class SkillLinkOptions {
  @CliOption(
    abbr: 'c',
    help:
        'Path to the configuration file.\n'
        'Defaults to \$documentedConfigLocation',
  )
  final String? config;

  @CliOption(abbr: 'h', negatable: false, help: 'Print this usage information.')
  final bool help;

  SkillLinkOptions({this.config, this.help = false});
}

String get skillLinkUsage => _$parserForSkillLinkOptions.usage;
