/// Local netplay session state machine.
enum NetplayStatus {
  none,
  searching,
  hosting,
  inLobby,
  transferringRom,
  gaming,
}
