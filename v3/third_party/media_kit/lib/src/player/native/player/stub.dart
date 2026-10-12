/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.
import 'package:meta/meta.dart';

import 'package:media_kit/src/player/platform_player.dart';

export 'package:media_kit/src/player/native/utils/async_property_error.dart';

void nativeEnsureInitialized({String? libmpv}) {}

class NativePlayer extends PlatformPlayer {
  NativePlayer({required super.configuration});

  Future<String> getPropertyAsync(String property, {
    bool waitForInitialization = true,
    bool controlRead = false,
  }) => throw UnsupportedError('Native libmpv properties are unavailable');

  /// Whether the [NativePlayer] is initialized for unit-testing.
  @visibleForTesting
  static bool test = false;
}
