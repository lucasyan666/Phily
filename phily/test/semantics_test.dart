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

  group('GildedSwitch', () {
    testWidgets('toggles, and announces its name and state', (tester) async {
      final handle = tester.ensureSemantics();
      var value = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: StatefulBuilder(
                builder: (_, setState) => GildedSwitch(
                  value: value,
                  semanticLabel: 'Always show level line',
                  onChanged: (v) => setState(() => value = v),
                ),
              ),
            ),
          ),
        ),
      );

      expect(
        tester.getSemantics(find.byType(GildedSwitch)),
        matchesSemantics(
          label: 'Always show level line',
          isButton: true,
          hasTapAction: true,
          hasEnabledState: true,
          isEnabled: true,
          hasToggledState: true,
          isToggled: false,
        ),
      );

      await tester.tap(find.byType(GildedSwitch));
      await tester.pumpAndSettle();
      expect(value, isTrue);
      expect(
        tester.getSemantics(find.byType(GildedSwitch)),
        matchesSemantics(
          label: 'Always show level line',
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

    testWidgets('wears the brand gold when on, glass when off', (tester) async {
      // The point of replacing Switch.adaptive: no iOS green anywhere.
      for (final on in [true, false]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: GildedSwitch(value: on, onChanged: (_) {}),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final box = tester.widget<AnimatedContainer>(
          find.descendant(
            of: find.byType(GildedSwitch),
            matching: find.byType(AnimatedContainer),
          ),
        );
        final decoration = box.decoration! as BoxDecoration;
        final colors = (decoration.gradient! as LinearGradient).colors;
        expect(
          colors.contains(kGold),
          on,
          reason: on ? 'on track should be gilt' : 'off track should be glass',
        );
      }
    });
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
