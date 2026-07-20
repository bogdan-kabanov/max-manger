import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_state.dart';
import 'account_map/account_map_canvas.dart';
import 'max_browser_panel.dart';

/// Central workspace: Figma-like account map + optional MAX browser drawer.
class HubCenterPanel extends StatelessWidget {
  const HubCenterPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final drawerOpen = state.browserDrawerOpen && state.selectedAccount != null;

    return Column(
      children: [
        Expanded(child: AccountMapCanvas()),
        if (drawerOpen)
          const SizedBox(
            height: 420,
            child: MaxBrowserPanel(),
          ),
      ],
    );
  }
}
