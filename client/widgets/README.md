# Widgets Module

This module contains the code for the UI widgets used in the HayChat client.
It utilizes the Raylib library for rendering and input handling, and `core:container/handle_map` for storing widgets in memory.
The widgets are designed to be flexible and customizable, allowing for a wide range of UI designs.

## Widget

The is the base struct for all widgets. It contains common properties and event handlers that are shared across different widget types. Each widget has a unique handle that can be used to reference it in the widget map.

### Panel

Panels are containers that can hold other widgets. They are used to group widgets together and manage their layout. Similar to VBox and HBox in other UI frameworks, you also have Overlay that is used to stack widgets on top of each other (you manually manage their positions).

### Button

Buttons are interactive widgets that can be clicked by the user. They can be used to trigger actions or toggle states. They have different types, such as regular buttons, toggle buttons, and radio buttons.

TODO: Add radio/checkbox options to buttons.

### Image

Images are widgets that behave like buttons but display an image instead of text. They can be used for icons, avatars, or any other visual element that requires interaction.

### Text

Text widgets are used to display static or dynamic text. They can be styled with different fonts, sizes, colors, and alignments. Text widgets can also be used as input fields for user interaction.

### FlexSpacer

FlexSpacer widgets are used to create flexible space between other widgets. They expand to fill available space, helping to create responsive layouts.

### Spacer

Spacer widgets are used to create fixed space between other widgets. They do not expand and are useful for maintaining consistent spacing in layouts.

## Requirements

- `vendor:raylib`

## License

The code in this module is licensed under the MIT License. See the [LICENSE](./LICENSE) file for more details.
