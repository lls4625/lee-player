import 'package:flutter/services.dart';

const appMainOrientations = <DeviceOrientation>[
  DeviceOrientation.portraitUp,
];

Future<void> lockAppMainToPortrait() =>
    SystemChrome.setPreferredOrientations(appMainOrientations);
