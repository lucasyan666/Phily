// VoiceOver contract for the shared controls. Every small control in the app
// is a PopTap, so this is where the button trait, the name and the on/off
// state come from: an icon-only glass button is named by [semanticLabel], a
// text chip is named by its own text, and a toggle announces its state.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phily/theme.dart';

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(body: Center(child: child)),
  ),
);

void main() {
  testWidgets('an icon-only glass button is a named, tappable button', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      GlassRoundButton(
        icon: Icons.ios_share_rounded,
        onTap: () {},
        semanticLabel: 'Share',
      ),
    );
    expect(
      tester.getSemantics(find.byType(GlassRoundButton)),
      matchesSemantics(
        label: 'Share',
        isButton: true,
        hasTapAction: true,
        hasEnabledState: true,
        isEnabled: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('a toggle announces its state', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      GlassRoundButton(
        icon: Icons.star_rounded,
        onTap: () {},
        semanticLabel: 'Favourite',
        toggled: true,
      ),
    );
    expect(
      tester.getSemantics(find.byType(GlassRoundButton)),
      matchesSemantics(
        label: 'Favourite',
        isButton: true,
        hasTapAction: true,
        hasEnabledState: true,
        isEnabled: true,
        hasToggledState: true,
        isToggled: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('a text chip is named by its text, with long-press exposed', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      GlassSquareButton(
        onTap: () {},
        onLongPress: () {},
        semanticLabel: 'About this guide',
        child: const Text('i'),
      ),
    );
    final node = tester.getSemantics(find.byType(GlassSquareButton));
    expect(
      node,
      matchesSemantics(
        label: 'About this guide\ni',
        isButton: true,
        hasTapAction: true,
        hasLongPressAction: true,
        hasEnabledState: true,
        isEnabled: true,
      ),
    );
    await _pump(tester, PopTap(onTap: () {}, child: const Text('GOT IT')));
    expect(
      tester.getSemantics(find.byType(PopTap)),
      matchesSemantics(
        label: 'GOT IT',
        isButton: true,
        hasTapAction: true,
        hasEnabledState: true,
        isEnabled: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('a selectable row announces its name, price and selection', (
    tester,
  ) async {
    // The paywall's tier rows are PopTaps now, so this is their contract:
    // one merged node carrying the spoken label and the selected state, not
    // three unnamed fragments.
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      PopTap(
        onTap: () {},
        semanticLabel: 'Yearly, £19.99 per year',
        toggled: true,
        child: const SizedBox(width: 300, height: 44),
      ),
    );
    expect(
      tester.getSemantics(find.byType(PopTap)),
      matchesSemantics(
        label: 'Yearly, £19.99 per year',
        isButton: true,
        hasTapAction: true,
        hasEnabledState: true,
        isEnabled: true,
        hasToggledState: true,
        isToggled: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('a disabled control is not announced as a button', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      const GlassRoundButton(
        icon: Icons.delete_outline_rounded,
        onTap: null,
        semanticLabel: 'Delete',
      ),
    );
    expect(
      tester.getSemantics(find.byType(GlassRoundButton)),
      matchesSemantics(
        label: 'Delete',
        isButton: false,
        hasEnabledState: true,
        isEnabled: false,
      ),
    );
    handle.dispose();
  });
}
