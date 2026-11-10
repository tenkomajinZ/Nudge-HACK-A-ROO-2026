# Nudge · Hackaroo Demo

Nudge is an Android study companion by Jason P. Nguyen. The demo lets you pick a task, set a focus rhythm, take a timed break, and try Active Recall with an offline quiz.

## Try the demo

Install Flutter and the Android SDK, then start an Android emulator. Run:

```text
flutter pub get
flutter run
```

1. Add a task such as **Study Skills**.
2. Choose **Active Recall**, read the sample notes, and select **Use sample notes**.
3. Pick a rhythm, start preparation, and study. To reach the quiz quickly, skip preparation, study briefly, and select **I’m done studying**.
4. Start recall, check an answer, and review the results.

The notes, questions, and accepted answers are bundled fixtures. The demo runs offline with a separate Android app ID and saves its own study history on the device.

## Source

- [Flutter screens](lib/) and [widget tests](test/)
- [Bundled quiz and notes](assets/recall/)
- [Offline music credits](assets/audio/LICENSE.txt)

Run `flutter analyze` and `flutter test` to check the frontend.
