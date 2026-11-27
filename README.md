# Retina-Code
A code editor for Mac, with nostalgic LCD font rendering of the 2013 MacBook era

## 50+ languages supported
<img width="631" height="476" alt="image" src="https://github.com/user-attachments/assets/58f03a94-316d-433f-a5c5-8b76617abe5d" />

## Vim mode
<img width="628" height="442" alt="image" src="https://github.com/user-attachments/assets/8e692ba4-765f-451b-bd0d-0d478da276fd" />

## Full LSP support for most languages
<img width="659" height="539" alt="image" src="https://github.com/user-attachments/assets/715db2f8-1f1f-4fa4-8a97-291aab37a42e" />

## LSP Errors
<img width="376" height="79" alt="image" src="https://github.com/user-attachments/assets/a1ebba9f-5cd4-46bd-a8e6-bd950130950d" />

## LSP and word-based autocomplete
<img width="408" height="248" alt="image" src="https://github.com/user-attachments/assets/cddf640a-9c71-4b0c-bca0-63071fdc30e9" />

## Debugger (LLDB) for most languages
<img width="738" height="628" alt="image" src="https://github.com/user-attachments/assets/b6c415a1-55bd-487a-b5c0-58ea5d19173b" />

## Screenshots
<img width="952" height="788" alt="Screenshot 2026-11-19 at 9 52 57 PM" src="https://github.com/user-attachments/assets/fc3ade20-9d61-42a5-83bf-07af8437963a" />
<img width="1082" height="817" alt="Screenshot 2026-11-21 at 9 47 02 AM" src="https://github.com/user-attachments/assets/a495444f-6c07-40d6-976b-ecf3e3f75931" />
<img width="968" height="683" alt="Screenshot 2026-11-21 at 9 49 51 AM" src="https://github.com/user-attachments/assets/944e37df-dd17-4400-9cde-42fd48a4c6f9" />

## Dark theme
<img width="968" height="683" alt="Screenshot 2026-11-21 at 9 50 41 AM" src="https://github.com/user-attachments/assets/d3d9c152-9e1d-4374-9c21-78e8f13c9402" />

## Other themes
Github Dark:
<img width="968" height="683" alt="Screenshot 2026-11-21 at 9 56 18 AM" src="https://github.com/user-attachments/assets/debfb4f2-cba0-4c55-b2fd-4a15de1c1efe" />
Tokyo Night:
<img width="968" height="683" alt="image" src="https://github.com/user-attachments/assets/2490efed-860d-4d47-aa0c-0d7c30a1846c" />
Visual Studio 2012 Dark:
<img width="968" height="683" alt="image" src="https://github.com/user-attachments/assets/14c8f0ef-64fb-46bc-97ff-c74c0995146f" />

## Theme picker:
<img width="832" height="646" alt="Screenshot 2026-11-21 at 9 52 35 AM" src="https://github.com/user-attachments/assets/15387282-9866-4f31-ad1e-dfe69882352f" />
<img width="832" height="646" alt="image" src="https://github.com/user-attachments/assets/b792a7c8-7252-47cf-9b00-252898185a70" />

## Settings
You can tweak the look of the LCD text effect

<img width="624" height="484" alt="Screenshot 2026-11-21 at 9 52 56 AM" src="https://github.com/user-attachments/assets/1780ef84-aa5e-4742-aae1-0e8c7a44e87f" />

## Building
The editor code shared by both frontends lives in `source/`. Each platform layer has its own folder, `source/mac_appkit/` and `source/qt/`. Each build compiles one file, `source/main_appkit.mm` or `source/main_qt.cpp`, which includes everything it needs.

**macOS (AppKit):** run `./build.sh` in the project's root directory.

**Windows (Qt):** install Qt 6 with the MSVC 64-bit kit and Visual Studio's C++ tools. Check the two paths at the top of `build.bat`, then run it. The app is `build\RetinaCode.exe`.

## Usage
[Download the latest release](https://github.com/sackboy19/Retina-Code/releases/latest), then run Retina Code.app

If macOS blocks the first launch, go to System Settings -> Privacy & Security and choose Open Anyway

Report any issues you have, bugs, or feature requests please! :D

## Disclaimers
All theme credits and licenses are in THEME_CREDITS.txt.
AI Disclaimer: The code is pretty terrible, the project was made with AI code writing.
