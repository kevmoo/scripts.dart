import 'dart:io';

import 'package:kevmoo_scripts/src/skill_link_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

void main() {
  group('skill_link tests', () {
    test('missing config file returns 78', () async {
      final code = await runSkillLink(
        configPath: p.join(d.sandbox, 'missing.yaml'),
        defaultHomeDir: d.sandbox,
      );
      expect(code, 78);
    });

    test('skillLinkUsage matches expected', () {
      expect(skillLinkUsage, r'''
-c, --config    Path to the configuration file.
                Defaults to $documentedConfigLocation
-h, --help      Print this usage information.''');
    });

    test('executes logic and creates missing symlinks correctly', () async {
      await d.dir('source_dir', [
        d.dir('.agent', [
          d.dir('skill_a', [d.file('SKILL.md', 'skill content')]),
          d.dir('ignored_dir', [d.file('other.txt', 'ignored')]),
        ]),
      ]).create();

      await d.dir('target_dir', []).create();

      await d.file('config.yaml', '''
sources:
  - ${p.join(d.sandbox, 'source_dir')}
targets:
  - ${p.join(d.sandbox, 'target_dir')}
''').create();

      final code = await runSkillLink(
        configPath: p.join(d.sandbox, 'config.yaml'),
        defaultHomeDir: d.sandbox,
      );
      expect(code, 0);

      // Verify the link was created
      final linkPath = p.join(d.sandbox, 'target_dir', 'skill_a');
      final link = Link(linkPath);
      expect(link.existsSync(), isTrue);
      expect(
        link.targetSync(),
        p.join(d.sandbox, 'source_dir', '.agent', 'skill_a'),
      );
    });

    test('handles broken symlinks inside source gracefully', () async {
      // Create directories
      await d.dir('source_dir', [
        d.dir('.agent', [
          d.dir('skill_a', [d.file('SKILL.md', 'skill content')]),
        ]),
      ]).create();
      await d.dir('target_dir').create();

      // Setup config
      await d.file('config.yaml', '''
sources:
  - ${p.join(d.sandbox, 'source_dir')}
targets:
  - ${p.join(d.sandbox, 'target_dir')}
''').create();

      // Create a broken symlink pointing INSIDE a source
      final targetPath = p.join(d.sandbox, 'target_dir');
      final brokenPath = p.join(targetPath, 'broken_skill');
      final brokenTarget = p.join(
        d.sandbox,
        'source_dir',
        '.agent',
        'broken_skill',
      );
      Link(brokenPath).createSync(brokenTarget);

      expect(Link(brokenPath).existsSync(), isTrue);

      final code = await runSkillLink(
        configPath: p.join(d.sandbox, 'config.yaml'),
        defaultHomeDir: d.sandbox,
      );

      expect(code, 0);

      // Verification: broken symlink inside sources should be deleted!
      expect(Link(brokenPath).existsSync(), isFalse);
    });

    test('skips duplicate skill directories and prints a warning', () async {
      await d.dir('source_dir_1', [
        d.dir('.agent', [
          d.dir('skill_a', [d.file('SKILL.md', 'skill content 1')]),
        ]),
      ]).create();
      await d.dir('source_dir_2', [
        d.dir('.agent', [
          d.dir('skill_a', [d.file('SKILL.md', 'skill content 2')]),
          d.dir('skill_b', [d.file('SKILL.md', 'skill content b')]),
        ]),
      ]).create();
      await d.dir('target_dir').create();

      await d.file('config.yaml', '''
sources:
  - ${p.join(d.sandbox, 'source_dir_1')}
  - ${p.join(d.sandbox, 'source_dir_2')}
targets:
  - ${p.join(d.sandbox, 'target_dir')}
''').create();

      late int code;
      await expectLater(() async {
        code = await runSkillLink(
          configPath: p.join(d.sandbox, 'config.yaml'),
          defaultHomeDir: d.sandbox,
        );
      }, prints(contains('skill_a -> WILL BE IGNORED. Duplicate skill name.')));

      expect(code, 0);

      final linkA = Link(p.join(d.sandbox, 'target_dir', 'skill_a'));
      expect(linkA.existsSync(), isTrue);
      expect(
        linkA.targetSync(),
        p.join(d.sandbox, 'source_dir_1', '.agent', 'skill_a'),
      );

      final linkB = Link(p.join(d.sandbox, 'target_dir', 'skill_b'));
      expect(linkB.existsSync(), isTrue);
      expect(
        linkB.targetSync(),
        p.join(d.sandbox, 'source_dir_2', '.agent', 'skill_b'),
      );
    });
    test('warns when unable to create symlink due to existing file', () async {
      await d.dir('source_dir', [
        d.dir('.agent', [
          d.dir('skill_a', [d.file('SKILL.md', 'skill content')]),
        ]),
      ]).create();

      await d.dir('target_dir', [
        // Create a regular file with the same name as the skill
        d.file('skill_a', 'I am a file, not a symlink'),
      ]).create();

      await d.file('config.yaml', '''
sources:
  - ${p.join(d.sandbox, 'source_dir')}
targets:
  - ${p.join(d.sandbox, 'target_dir')}
''').create();

      late int code;
      await expectLater(
        () async {
          code = await runSkillLink(
            configPath: p.join(d.sandbox, 'config.yaml'),
            defaultHomeDir: d.sandbox,
          );
        },
        prints(
          contains(
            'skill_a: Warning! Cannot create symlink at '
            '${p.join(d.sandbox, 'target_dir', 'skill_a')} '
            'because a file or directory already exists there.',
          ),
        ),
      );
      expect(code, 0);
    });

    test('warns on symlink to non-existent dir outside sources', () async {
      await d.dir('source_dir', [
        d.dir('.agent', [
          d.dir('skill_a', [d.file('SKILL.md', 'skill content')]),
        ]),
      ]).create();
      await d.dir('target_dir').create();

      final targetPath = p.join(d.sandbox, 'target_dir');
      final brokenPath = p.join(targetPath, 'mysterious_link');
      Link(
        brokenPath,
      ).createSync(p.join(d.sandbox, 'some', 'random', 'nowhere'));

      await d.file('config.yaml', '''
sources:
  - ${p.join(d.sandbox, 'source_dir')}
targets:
  - $targetPath
''').create();

      late int code;
      await expectLater(
        () async {
          code = await runSkillLink(
            configPath: p.join(d.sandbox, 'config.yaml'),
            defaultHomeDir: d.sandbox,
          );
        },
        prints(
          contains(
            'mysterious_link: Warning! Symlink points to a non-existent '
            'directory that is NOT a child of configured sources.',
          ),
        ),
      );
      expect(code, 0);
    });

    test(
      'warns when finding unexpected symlink to existing directory',
      () async {
        await d.dir('source_dir', [
          d.dir('.agent', [
            d.dir('skill_a', [d.file('SKILL.md', 'skill content')]),
          ]),
        ]).create();

        final unrelatedDir = p.join(d.sandbox, 'unrelated_dir');
        Directory(unrelatedDir).createSync(recursive: true);

        await d.dir('target_dir').create();

        final targetPath = p.join(d.sandbox, 'target_dir');
        final unexpectedPath = p.join(targetPath, 'unexpected_link');
        Link(unexpectedPath).createSync(unrelatedDir);

        await d.file('config.yaml', '''
sources:
  - ${p.join(d.sandbox, 'source_dir')}
targets:
  - $targetPath
''').create();

        late int code;
        await expectLater(
          () async {
            code = await runSkillLink(
              configPath: p.join(d.sandbox, 'config.yaml'),
              defaultHomeDir: d.sandbox,
            );
          },
          prints(
            contains(
              'unexpected_link: Warning! Unexpected symlink points to an '
              'existing directory: $unrelatedDir',
            ),
          ),
        );
        expect(code, 0);
      },
    );
  });
}
