# Catch Everything user guide

[한국어 안내: USER_GUIDE.ko.md](USER_GUIDE.ko.md)

This guide is for people who are not developers and want to install Catch Everything for the first time. The app is called Catch Everything, short name CATE; its file is `CATE.app`. All you need is one installer file, `CATE-<version>.dmg`. If the person who built your copy chose other names, your file and your app carry those names instead; everything else in this guide stays the same. The page for people who build the app themselves and hand it to others is [DISTRIBUTE.md](DISTRIBUTE.md).

## Read this first

- The app records **everybody's voice** in a call and **your own microphone**. Your microphone is recorded even when you mute yourself in the call app. Telling the participants and getting any consent that is needed is your responsibility (section 9).
- So far **only Zoom calls** have been verified in real calls (section 10).
- The installation needs internet, a download of about 4 GB and 12 GB of free disk space. It takes 10 to 40 minutes.
- The app is signed with a certificate its builder made for themselves (self-signed), and Apple has not notarized it. A warning when you open it for the first time is normal (section 3). For the same reason macOS cannot tell you who made the file. Open only files you got from a source you trust (section 2).

## 1. What you need

- An Apple silicon Mac (M1 or newer) with macOS 14.4 or later. Check it under the Apple logo at the top left > About This Mac. Intel Macs do not work.
- An internet connection. (If a VPN, proxy or firewall of a work or school network blocks pypi.org, huggingface.co or github.com, the installation stops. Ask the administrator of that network.)
- For meeting notes (the summary after a meeting) you need an Anthropic API key and the Claude Code tool. Without them, recording and the transcript (the speech turned into text) still work.

## 2. Getting the file

Download `CATE-<version>.dmg` from the place the person who built it chose (the project's releases page, or a file-sharing service such as a cloud drive link). First check that you got it from a person or a place you trust. The app can record your microphone and the system audio, so a file that somebody has tampered with is dangerous.

The `.sha256` file next to it (or the checksum written in the description where you downloaded it) lets you check that the file is unchanged. In Terminal, run `shasum -a 256 CATE-<version>.dmg`: the number it prints must be the number in the `.sha256` file. This check only shows that the file was not damaged or changed on the way. It does not tell you whether the place that gave you the checksum can be trusted.

## 3. Installing (once)

1. Double-click the downloaded `.dmg`. A window opens.
2. Drag the **CATE** icon in the window onto the **Applications** folder icon. The same steps are in short in `README-install.txt` inside the window.
3. Open Applications in the Finder, **Control-click** CATE (or right-click it), choose **Open**, and click **Open** once more in the dialog. The warning means "an app Apple has not checked". The app is signed with a certificate its builder made for themselves (self-signed) and Apple has not notarized it.
4. On recent macOS (15 and later) the dialog may have no **Open** button. Then close the dialog, go to **System Settings > Privacy & Security**, scroll down to the message about Catch Everything (or CATE, the name of the file) and click **Open Anyway**. macOS asks for your password or Touch ID. The wording differs a little between macOS versions.
5. When the app has opened, an icon appears in the menu bar at the top right. A notch or a menu bar organizer app can hide it.

If you open the app straight from inside the disk image, nothing is installed and a message says "Move Catch Everything to the Applications folder first". Start again from step 2.

## 4. First start: installing the components

At the first start a window appears: "Catch Everything needs to install its components (about 4 GB download, needs internet). Start now?" (If your Mac's first language is Korean, this window is in Korean.) Click **Start**: a **Terminal** window opens and 7 steps run one after the other. If you click **Later**, the menu bar icon keeps the item "Components: not installed - run installer", and clicking it opens the same window. **Until the installation has finished, the app records nothing.** The first line of the menu says "Auto recording is off until the installer has finished", and it goes away by itself within a few seconds after the installation is done. Only one installer window opens at a time. If one is already open, the app tells you "The installer is already running".

| Step | What happens | What you do |
|---|---|---|
| 1 | Shows the recording notice and checks that the Mac fits (Apple silicon, macOS 14.4 or later, 12 GB free, internet) | Read the notice and type **yes** if you will follow it |
| 2 | Unpacks the Python that is inside the app | Nothing |
| 3 | Downloads the program packages and the speech recognition model (about 3.1 GB). This takes the longest | Keep the Mac awake and online. Closing the window stops it; running it again continues the download |
| 4 | Asks for an Anthropic API key for meeting notes (it does not ask if one is already stored; it does not read the key, it only checks whether the item exists) | **1**: type it now (a macOS tool asks for the key and what you type is not shown; the key does not pass through the installer script). **2**: type it later in the app's Settings. Without a key only recording and the transcript work, and no meeting note is made |
| 5 | Creates the settings file. The name is the first word of your Mac user name, the language follows the Mac. An existing settings file is not touched | Nothing |
| 6 | Chooses where meetings are stored. The default is `~/Meetings` on your Mac. If exactly one Google Drive account is connected, it asks whether to store the meetings in Drive | Storing in Drive uploads the audio to Drive too. If you are unsure, just press Enter (the default is no) |
| 7 | The macOS permission requests appear (section 5). A summary follows | Click Allow |

- If lines in English appear in between and the installation does not stop, leave them. In particular, a note about Python 3.12 can appear.
- If it stops or fails, it prints the step number, the likely cause and "run this script again". Open it again the same way (the menu item, or Start in the alert): finished steps are skipped and it continues where it stopped. Existing files are not overwritten.
- When the installation is done, quit the app once with **Quit** in the menu bar icon and open it again. Then it reads the new settings.

## 5. The permissions macOS asks for

| Permission | Why it is needed | If you do not allow it |
|---|---|---|
| Microphone | Records your voice (also when you are muted) | Your voice is missing |
| System audio recording | Records the other people (the sound that comes out of your Mac's speakers) | The other people's sound is empty |
| Notifications | Tells you when a recording starts and ends, and when something goes wrong | The app can record without you noticing |
| Google Drive folder | Only if you chose Drive as the place to store meetings | Nothing can be stored in Drive |

The Chrome automation permission appears only if you turn on Google Meet detection yourself (it is off by default). If you refused a permission by mistake, find Catch Everything under **System Settings > Privacy & Security** and turn it on.

## 6. Where recordings and notes are stored

- A finished meeting is stored in the folder `~/Meetings/year-month/year-month-day_hourminute_title/` (if you chose Drive in step 6, in `My Drive/Meetings` of Google Drive). Inside are `transcript.md` (the transcript as spoken), `meeting-note.md` (the meeting note) and the audio `.m4a` files.
- While a meeting is processed, it is kept temporarily in `~/Library/Application Support/MeetingCapture/sessions`. The folder is called MeetingCapture, not Catch Everything: the data folder, the log folder and the Keychain items keep that internal name, so that what is already on a Mac stays where it is.
- **Open Meeting Folder** in the menu bar icon opens the most recent meeting folder.
- **If you chose Google Drive as the place to store meetings, the whole folder including the audio is uploaded to Drive, and everybody who has access to that folder can see it.**

## 7. Pause, stop, quit

While the app is open, it starts recording by itself when it detects a call and sends a notification (only Zoom has been verified in real calls). It detects Zoom, Microsoft Teams, and the other call apps such as Slack huddles, Webex, Discord, FaceTime, KakaoTalk and WhatsApp. **Calls of personal messengers are included.** Google Meet is off by default. To stop recording an app, switch it off in **Call Apps** in the menu, or block an app that was recorded once with **Never record <app name>**. Until the installation of section 4 is finished, nothing is recorded. When the menu bar icon turns red, a recording is running. The menu names are shown in English.

| Menu item | What it does |
|---|---|
| Pause Auto Recording / Resume Auto Recording | Pauses automatic recording and turns it on again |
| Start Recording Now / Stop Recording Now | Starts and stops a recording by hand |
| Local-Only Meeting | For this one meeting only: the transcript is made on your Mac only, with no meeting note from Claude and no Drive upload |
| Pause Microphone | Only shown if you turned it on in the settings. Temporarily stops recording your voice |
| Settings… | Change your name, the language, the Claude key, the apps to detect and more |
| Quit | Quits the app completely. Nothing is recorded until you open it again |

The app has to be open for automatic recording. Opening it automatically when the Mac starts is not part of this installation.

## 8. What leaves your Mac, and when

| What | Where to | When |
|---|---|---|
| Program packages and the speech recognition model | Download only (PyPI, Hugging Face, GitHub) | Once, at installation |
| Speech recognition | Does not leave. By default it runs on your Mac. Audio does not go to Claude | Always |
| Transcript text, meeting title hints, the word list | Anthropic's Claude (when the meeting note is made) | Meetings that are not Local-Only, when an API key and Claude Code are present |
| The whole meeting folder including the audio | The storage place. If you chose Google Drive: Drive, and everybody who has access to it | Every meeting that is not Local-Only |
| Calendar information | Does not leave by default (calendar lookup is off) | Only when you turn it on in the settings |
| External speech recognition services | Off by default. To turn one on you must type a consent sentence in Terminal yourself. The settings window does not give the consent for you | Only when you turned it on |

For a meeting with Local-Only Meeting on, rows three to six of the table (Claude, a storage place such as Drive, the calendar, external speech recognition) are all blocked. A meeting title and parts of the conversation can remain in the log, so check the log before you send it to anybody.

## 9. Telling the participants

Before you record, tell the participants and get their consent if it is needed. The consent that is needed differs by country, by the rules of your organisation or company, and by the nature of the meeting. If you are not sure, it is safest to ask somebody who knows about law or data protection first. An example wording:

> This meeting is being recorded so that meeting notes can be written. The speech is turned into text on my computer, and that text may be sent to Anthropic's Claude to be summarised. If you do not want to be recorded, please say so now.

Do not use the app in meetings where regulated or confidential content comes up, such as patient information or customer secrets, unless your contracts and the rules of your organisation allow it. Remember that even with Local-Only Meeting on, the audio and the transcript stay on your Mac.

## 10. What has been verified and what has not

- Verified: **Zoom calls** are detected and recorded in real calls.
- Not verified: the detection of calls in Microsoft Teams, Google Meet and the other apps such as Slack huddles, Webex, Discord, FaceTime, KakaoTalk and WhatsApp. Even if it works, it cannot be guaranteed. When a call is detected, recording starts, so switch off in Call Apps (section 7) any app whose calls must not be recorded.
- Not verified: the settings window and this installation alert have only been drawn on screen, never used in a real working environment. Tell us if something looks odd.
- Not verified: running this installation from start to finish on a new Mac with nothing installed, and a real transcription with the Python 3.12 that is inside the app (installing the packages and importing them was checked on the Mac where the app was built). If you get stuck, take a photo of the last few lines of the Terminal window and send it along with your question.
- Because Apple has not notarized the app, the warning in section 3 is normal. There is no plan or date for notarization.

## 11. If something goes wrong

| Symptom | What to try |
|---|---|
| The app says it "cannot be opened" | Control-click > Open from section 3; if that does not work, **Open Anyway** in System Settings |
| The installer window appears every time you open the app | Go through the Terminal installation to the end. If it still appears after it finished, ask (last row) |
| "The installer is already running" | Finish it in the Terminal installer window that is already open. If you cannot find it, close all Terminal windows that show the installer and start it again with the menu item |
| The installation is finished but nothing is recorded | If the first line of the menu says "Auto recording is off until the installer has finished", the installation is not finished yet. Check that the Terminal installer window got to its end message |
| The installation stopped half way | Read the step number and the cause on the screen, check the internet and the disk space, and start it again. It continues where it stopped |
| No notifications arrive | Allow Catch Everything under System Settings > Notifications |
| The other people's voices are empty | Check the system audio recording permission (section 5) |
| No meeting note is made | Check that an API key is entered (Settings > Claude), that Claude Code is installed, and that Local-Only is not on |
| Anything else | **Ask the person who sent you this file, or the project page you got it from.** **Open Logs** in the menu opens the log, but it can contain meeting titles, so check it before you send it |

## 12. Uninstalling

1. Quit the app with the menu bar icon > **Quit**.
2. Move CATE in Applications to the Trash.
3. Delete the folder `~/Library/Application Support/MeetingCapture` (it keeps the internal name). It holds the settings, the Python files and temporary recordings that have not yet been moved to the storage place.
4. If you typed a key, delete the item "MeetingCapture Anthropic API key" (the internal name again) in the Keychain Access app.
5. To delete the speech recognition model, delete the folder `~/.cache/huggingface/hub/models--mlx-community--whisper-large-v3-mlx` (about 3 GB).
6. Meeting folders that are already stored (`~/Meetings` or Drive) stay. Delete them yourself if you do not need them.
