/// Left-rail destinations. Accounts first (separated), then pipeline, then «Ещё».
enum AppNavPage {
  /// Accounts table + profile templates (top of rail, above pipeline).
  accounts,
  /// Groups catalog under Accounts: parse, paste links, assign to parents.
  catalogGroups,
  /// Campaigns: who sends, templates, launch, history.
  campaigns,
  /// Channel creation funnels (top rail with accounts/groups/campaigns).
  funnels,
  /// 1. Parse channels into catalog.
  parse,
  /// 2. Soft-assign catalog groups to matkas.
  assign,
  /// 3. Message templates + matka bindings.
  templates,
  /// 4. Distribute & join children by invite links.
  launch,
  /// 5. Pipeline journal + live actions.
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

  /// Work page that should fill the whole nav content area (no width cap).
  bool get isFullBleedPage =>
      this == accounts ||
      this == catalogGroups ||
      this == campaigns ||
      this == funnels;

  bool get isPipelineStep =>
      this == parse ||
      this == assign ||
      this == templates ||
      this == launch ||
      this == journal;

  bool get isWideWorkPage =>
      isPipelineStep ||
      this == accounts ||
      this == catalogGroups ||
      this == campaigns ||
      this == funnels ||
      this == groups ||
      this == chats ||
      this == mother ||
      this == automation ||
      this == more;
}
