/// Left-rail destinations. Pipeline first, then accounts, then «Ещё».
enum AppNavPage {
  /// 1. Parse channels into catalog.
  parse,
  /// 2. Soft-assign catalog groups to matkas.
  assign,
  /// 3. Message templates + matka bindings.
  templates,
  /// 4. Channel creation funnels.
  funnels,
  /// 5. Distribute & join children by invite links.
  launch,
  /// 6. Pipeline journal + live actions.
  journal,
  profiles,
  addAccount,
  /// Hub for secondary tools (map groups, chats, advanced mother, auto…).
  more,
  // Secondary (opened from «Ещё», not primary rail).
  groups,
  chats,
  mother,
  automation,
  emulator,
  help,
  about;

  /// Account map lives only on the home page («Профили»).
  bool get showsAccountMap => this == profiles;

  bool get isPipelineStep =>
      this == parse ||
      this == assign ||
      this == templates ||
      this == funnels ||
      this == launch ||
      this == journal;

  bool get isWideWorkPage =>
      isPipelineStep ||
      this == groups ||
      this == chats ||
      this == mother ||
      this == automation ||
      this == more;
}
