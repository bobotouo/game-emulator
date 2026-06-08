import '../emulator_loop/emulator_loop_ffi.dart' as emu_loop;

const int kNetplayButtonB = 0;
const int kNetplayButtonSelect = 2;
const int kNetplayButtonStart = 3;
const int kNetplayButtonUp = 4;
const int kNetplayButtonDown = 5;
const int kNetplayButtonLeft = 6;
const int kNetplayButtonRight = 7;
const int kNetplayButtonA = 8;

const int kNetplayMenuControlMask =
    (1 << kNetplayButtonSelect) |
    (1 << kNetplayButtonUp) |
    (1 << kNetplayButtonDown) |
    (1 << kNetplayButtonLeft) |
    (1 << kNetplayButtonRight);

const int kNetplayMenuStartMask = 1 << kNetplayButtonStart;
const int kNetplayMenuCoinMask = 1 << kNetplayButtonSelect;

/// Maps netplay player slot (1-based) to libretro port (0-based).
int netplaySlotToLibretroPort(int slot) => slot <= 0 ? 0 : slot - 1;

/// Applies a libretro joypad bitmask to the given port.
void applyNetplayInputMask(int port, int buttons) {
  emu_loop.setPortInputMask(port, buttons & 0xFFFF);
}

int inputStateToMask(Map<int, bool> state) {
  var mask = 0;
  for (final entry in state.entries) {
    if (entry.value && entry.key >= 0 && entry.key < 16) {
      mask |= 1 << entry.key;
    }
  }
  return mask;
}

/// FC/NES and arcade use host-authoritative lockstep netplay.
bool isHostAuthoritativeNetplayExtension(String? extension) {
  if (extension == null || extension.isEmpty) {
    return false;
  }
  final normalized = extension.startsWith('.')
      ? extension.toLowerCase()
      : '.${extension.toLowerCase()}';
  return const {
    '.nes',
    '.fc',
    '.fds',
    '.unf',
    '.unif',
    '.zip',
    '.7z',
  }.contains(normalized);
}

String? netplayExtensionFromPath(String? path) {
  if (path == null || path.isEmpty) {
    return null;
  }
  final dot = path.lastIndexOf('.');
  if (dot < 0 || dot >= path.length - 1) {
    return null;
  }
  return path.substring(dot).toLowerCase();
}
