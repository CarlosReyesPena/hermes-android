import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/utils/project_appearance.dart';

void main() {
  test('uses a server project hex color when it is valid', () {
    expect(
      projectDisplayColor('#2F81F7', fallback: Colors.orange),
      const Color(0xFF2F81F7),
    );
    expect(
      projectDisplayColor('#802F81F7', fallback: Colors.orange),
      const Color(0x802F81F7),
    );
  });

  test('falls back when a server project color is absent or malformed', () {
    expect(projectDisplayColor(null, fallback: Colors.orange), Colors.orange);
    expect(projectDisplayColor('blue', fallback: Colors.orange), Colors.orange);
    expect(projectDisplayColor('#12', fallback: Colors.orange), Colors.orange);
  });

  test('maps server project icon names and safely falls back', () {
    expect(projectDisplayIcon('rocket'), Icons.rocket_launch_rounded);
    expect(projectDisplayIcon('repo'), Icons.account_tree_rounded);
    expect(projectDisplayIcon('device-mobile'), Icons.phone_android_rounded);
    expect(projectDisplayIcon(null), Icons.folder_rounded);
    expect(projectDisplayIcon('future-desktop-icon'), Icons.folder_rounded);
  });
}
