/// Result of loading a ROM in-process to verify playability / capture a frame.
class RomLoadProbe {
  const RomLoadProbe({
    required this.success,
    this.thumbnailPath,
    this.errorMessage,
  });

  final bool success;
  final String? thumbnailPath;
  final String? errorMessage;
}
