# Changelog

Release notes per version. The section for the latest version is shown
in-app when the plugin offers its own update.

## 1.7.4 — 2026-10-29

- **A .flatpak file installs as a Flatpak.** Opening a downloaded
  `.flatpak` with the depot installed it as an AppImage: the file was
  copied into your AppImages folder and given a menu entry that could
  never start it. A `.flatpak` bundle or `.flatpakref` now installs as a
  Flatpak, as in GNOME Software: the dialog shows the app's name and icon,
  the runtime it needs comes along from its remote, and a newer build
  replaces the one you have. "Open with" offers the depot for both kinds
  of file. Thanks to @QuesoFresho for the report.

- **Only an AppImage is installed as an AppImage.** What a file is now
  comes from its contents, not its name. Anything else is turned away
  with a clear message instead of being installed as something it is not.

## 1.7.3 — 2026-10-28

- **A newer build than the list named counts as updated.** The list is as
  old as its check, and the repositories can move on before you press
  "Update all". The kernel went from 7.2.11 to 7.2.13 under rows that said
  7.2.12, and all eight kernel packages were then reported as "not
  updated — try again", though the run had installed them. A run now checks
  that the installed version is at least the one listed, using rpm's own
  version ordering.

- **An old failure no longer keeps a row red for days.** Why a package
  failed is kept across the shell's reload, so the row can still say
  so. But it stayed for as long as the package was waiting to be
  updated: "no newer build" from a mirror that was a day behind kept four
  rows red two days later, when updating them would have worked. A reason
  now goes away once a later check lists the package again, or when a
  different version is offered than the one that failed.

## 1.7.2 — 2026-10-27

- **Updates you just installed no longer come back hours later.** A run
  that also updated the shell restarts its update service, and that
  service keeps its list on disk. Restarted at the wrong moment, it came
  back with the list from before the run, and nothing asked again until
  the daily check: "Update all" then ran the same updates a second time.
  A list from a check older than the last run is now checked again by
  itself, and what a run installed stays off the list also when the run
  ended in the shell's reload.

- **A failed check says so above the list.** "Check failed" used to appear
  only when there was nothing to update. A check that fails halfway still
  leaves a list on screen, and that list may be missing things — a banner
  above the tabs now says so, with the reason and a button to check
  again. Thanks to @gitblit for the report that led there: Dux Shell's
  Flatpak check reported no updates at all as soon as one app needed a
  new runtime, which Dux Shell has since fixed.

- **Arch on CachyOS: updates no longer crash, and a crash no longer
  leaves pacman locked.** CachyOS's pacman accepts the CPU's feature
  levels (x86_64_v3) and ships most packages that way; the depot asked
  libalpm to accept x86_64 alone, and pyalpm turns that refusal into a
  crash. The accepted architectures now come from `pacman-conf`. A
  request is first worked out in a separate process, so whatever pyalpm
  still crashes on — a package conflict, for one — is reported with
  pacman's reason and changes nothing. And a lock left behind by an
  earlier crash is removed once nothing holds it, instead of blocking
  every pacman command until it is deleted by hand. Thanks to
  @Verilisity for the report, the analysis and the pull request this is
  built on.

## 1.7.1 — 2026-10-26

- **Arch: the update preview and the removal warning work.** Working out
  what an update or an uninstall would do needs no root, but on Arch it
  failed every time with "unable to lock database", so the preview of an
  update and the "this would also remove …" warning never appeared. They
  do now. Thanks to @Verilisity for the report and the analysis.

- **Arch: a failing mirror no longer crashes an update.** When a mirror
  failed while the databases were being refreshed, the update could crash
  and leave pacman's lock file behind, after which every pacman command
  refused to run until it was removed by hand. pacman now does that
  refresh itself, and a failing mirror is skipped, as `pacman -Syu` does.
  The download progress on Arch also shows real sizes again instead of
  nonsense. Thanks again to @Verilisity.

- **What was just updated stays off the list.** The list shown after a
  run could still offer updates that run had just installed, when the
  check that followed answered from what it knew before. Those are left
  out now; a newer version released since still shows up.

## 1.7.0 — 2026-10-21

- **Dank Software Depot is now Dux Software Depot.** DankMaterialShell
  became Dux Shell with 2.0, and the plugin follows, with Dux Labs' blessing.
  Nothing to do on your side: settings, holds, the action log and your
  AppImages carry over, and the bar widget stays where it is. An app
  launcher entry is renamed along with its icon, and if the depot opens
  .appimage files, it still does. One thing the plugin cannot change for
  you: the window's title is now "Dux Software Depot", so a window rule of
  your own that matches "Dank Software Depot" — to keep it tiled on niri,
  say, where DMS opens its windows floating — needs the new title.

- **Unofficial, and it says so.** The depot is a community plugin by an
  independent developer, not a Dux Labs product, and Dux Labs does not
  support it. The About page and the README now say that in so many words,
  and where problems with it should go instead.

- **Ready for Dux Shell 2.0.** The shell's logo next to its own packages and
  on the Updates tab disappeared under 2.0, which keeps the running shell
  somewhere else; it is found in either place now. The plugin also
  recognises the new configuration folder and the package names Dux Labs
  suggests to packagers (`dux-shell`, `dux-greeter`), so the shell's own
  update still runs last, after everything else.

- **Updates apt keeps back are held instead of failing.** On Debian and
  Ubuntu, `apt-get upgrade` leaves an update alone when it needs a new
  package, when an installed package does not allow the new version — dms
  pinning the quickshell it was built for — or when it is a phased update
  still rolling out. The window offered such updates anyway, and after a
  run reported them as "not updated — try again", which never helped. They
  now sit under Held packages with the reason, such as "kept back (via
  dms)", stay out of Update all, and come back by themselves once apt will
  install them. Thanks to @boembast for the report.

## 1.6.1 — 2026-10-13

- **Updates that were just installed no longer reappear after a run.**
  The check at the end of a run could join one the shell's update service
  had already started while the run was still installing. That check read
  the system from before the run, and the list came back offering exactly
  what had just been updated. The check after a run now always starts
  afresh.

## 1.6.0 — 2026-10-11

- **Buttons and lists without outlines, as in Material 3 Expressive.**
  Buttons, rows, cards and banners drew a thin outline; the shell itself
  has moved away from that, and the window now follows it (#28). How much
  a button matters shows in its fill: each area has at most one filled
  button, its main action — Update all, Install from Flathub, Open — and
  the rest are tonal, while "Read more" and "Show all" are plain text. The
  main button takes the colours set under Settings → Theme. Buttons that
  were joined into one pill without belonging together are separate now.
  List rows have a surface of their own instead of an outline, and show
  hover, selection, a failure or the installed source in that surface.
  Thanks to @apollo79 for the issue and to @JDKamalakar for the discussion.

- **Scrolling with a touchpad is smooth again, with momentum.** In
  Installed, Install and an app's details, every small touchpad movement
  jumped a whole wheel step, and a flick stopped dead. The mouse wheel
  keeps its smooth steps; the touchpad goes back to the shell's own
  scrolling. The Install tab's front page no longer stutters as each
  category comes into view: it is built row by row, like Installed. The
  settings and About pages scroll the way the rest of the shell does too,
  and show a scrollbar.

- **Put the widget on the bar from the plugin's settings.** Enabling the
  plugin did not put its widget anywhere; that took a trip to the bar's
  own settings. The plugin's settings in DMS now start with "On the main
  bar": choose left, centre or right and the widget goes there, or moves
  there if it is already on the bar.

- **Right-clicking the bar pill opens the window.** Whatever a left click
  is set to do, a right click always opens the full window; the setting
  "Bar click opens window" says so.

- **The bar's popout lists plugin and Homebrew updates.** They were counted
  — the pill and the popout's header said "1 update ready" — but not
  listed, so with only a plugin update pending the popout showed that
  count above "Your system is up to date!".

- **The globe and lock in an app's details say what they do.** Hovering
  them shows "Open website" with the address, and whether the lock holds
  the app back from updates or lets it update again.

- **A DMS plugin update shows what it changes.** The details of a plugin
  update showed the plugin's description and nothing about the update. They
  now show the release notes the author published for the new version, or
  the matching part of the plugin's changelog, or else the commits since
  your version — and the card shows the version it updates to. A plugin
  that shares its repository with others is offered an update whenever any
  of them changes; the details now say when nothing in it is about this
  plugin. Thanks to @JDKamalakar for the idea (#32).

- **On Fedora, a missing Flatpak library is named correctly.** When the
  Flatpak helper could not load its library, the app said "flatpak is
  missing" and offered to install flatpak — which was already installed.
  The library comes in flatpak-libs, which flatpak does not pull in; it is
  now the package named and installed. Found on Zirconium, which ships
  flatpak without it.

- **Removing an AppImage removes all of its launcher entries.** Many
  AppImages add a launcher entry of their own, and sometimes an autostart
  entry and an icon too. Removing the app took away only one of those
  entries, so the app could stay in the launcher without starting anything.
  Now every entry that starts the removed file goes, and so does an icon
  that only that app used.

- **An AppImage updated outside the depot is no longer offered again.** When
  an app's own updater, Gearlever or a manual copy replaced the file, the
  depot still judged it by the release it had installed, and kept offering
  the latest release however often it checked. It now notices that the file
  changed: if it matches the latest release, that release counts as
  installed.

- **An outdated Flatpak runtime is named once, with its version.** When
  Flathub stops maintaining a runtime version, it marks every extension of
  it too, and the Updates tab listed them all by name: "Mesa, Mesa (Extra),
  org.freedesktop.Platform.Locale, Intel VAAPI driver, Freedesktop
  Platform" — as if Mesa itself were no longer maintained. It now says
  "Freedesktop Platform 24.08 is no longer maintained", names the apps that
  still use it, and says so when none do. The notice can be dismissed; it
  comes back only when the situation changes, such as when the last app
  stops using the runtime.

## 1.5.0 — 2026-10-09

- **A BIOS update that needs the power adapter says so.** On battery
  power fwupd will not install system firmware, and the card looked like
  any other update — Update all then reported it installed while nothing
  had happened. The card now asks you to plug in the power adapter, Update
  all leaves it out until you have, and the card updates itself a few
  seconds after you plug in. A laptop lid that is closed, a battery that is
  too low or a device in use are named the same way, and the Firmware tab
  marks such devices *Needs power adapter* instead of showing them as not
  updatable.

- **Update these updates only that section.** The button on System
  packages and on Firmware also updated AppImages, DMS plugins and
  Homebrew.

## 1.4.4 — 2026-10-08

- **The update list can be scrolled during an update.** While packages were
  installing, the list rebuilt itself several times a second, so scrolling
  barely worked and kept jumping back to the top, and the scrollbar changed
  length as you scrolled. The list now only redraws the group a package
  moves into or out of, keeps its place, and knows its full height.

- **The scrollbar shows while you scroll Installed, Install and the details
  window.** Their smooth wheel scrolling never told the scrollbar, so it only
  appeared with the pointer right next to it.

- **The spinning refresh icon looks sharp.** In the window's header it
  turned jagged while spinning; in the bar and the popout it was slightly
  soft even at rest. All four are now crisp at rest and smooth while they
  turn.

## 1.4.3 — 2026-10-08

- **The refresh icon turns at a calm, steady pace.** Since 1.2.0 it took its
  speed from DMS's animation setting, so on a short setting it spun about
  five times a second, and with animations off it restarted every frame. It
  now turns once a second, as before 1.2.0, and so does the pulse of the
  active step in a run. With animations off or reduced motion on in DMS,
  neither moves at all.

- **The Install tab's rows are spaced like every other list.** Its rows sat
  8 to 12px apart where Updates, Installed, Firmware and the log use 2px.
  Headings and the space between categories are as they were. Thanks to
  @apollo79 (#29).

- **A held DMS plugin, Homebrew formula or AppImage stays held.** Holding
  one put it in the Held line, but it also stayed in its own section, was
  counted in the number of updates, and Update all updated it anyway. Held
  rpm packages and Flatpaks were never affected, because DMS filters those
  itself; the other three are found by the plugin, which now leaves out
  whatever you have held. Thanks to @JDKamalakar for the report (#30).

## 1.4.2 — 2026-10-01

- **Hovering no longer changes a row's or a button's shape.** Rows in every
  list and most buttons, the four in the window's header among them, rounded
  into a pill under the pointer, and buttons grew a little. Material 3
  Expressive, and DMS itself, keep hover to a light shade and save shape
  changes for interaction. A row now changes shape when you press it, and
  keeps that shape while its details are open. An expanded firmware or log
  entry keeps its corners, as expanded cards in DMS do; its shade and
  outline show it is open. A button changes shape while pressed, or while
  what it opens is showing. The coloured outline appears only for a selected
  row. Buttons still shrink slightly when pressed, but no longer grow under
  the pointer. Thanks to @apollo79 for pointing this out (#22).

- **An opening log or firmware entry stays inside its box.** While an
  entry grew to its new height, its opened lines were already at full size,
  and showed above and below the entry, over the ones around it. The entry
  now opens downward, within its own outline.

## 1.4.1 — 2026-10-01

- **RHEL, CentOS Stream, AlmaLinux and Rocky can install and update system
  packages.** They ship dnf 4 and have no python3-libdnf5, in the
  distribution or in EPEL, so every system update failed and the banner
  asked for a package that cannot be installed there. The plugin now uses
  dnf 4 on those systems, with the same per-package progress, plan preview,
  downgrades and security advisories. If the bindings are missing, the
  banner names `python3-dnf`. Tested on CentOS Stream 10 and AlmaLinux 10.
  Thanks to @kmf for the report (#27).

## 1.4.0 — 2026-10-01

- **An AppImage is read, never run, until you install it.** To show a
  file's name and icon the plugin used `--appimage-extract`, which executes
  the runtime embedded in the file: code chosen by whoever built it. That
  happened as soon as a downloaded AppImage was opened, before you pressed
  Install, and for AppImages in `~/AppImages` without a cached icon a few
  seconds after the shell started. The plugin now reads the desktop entry
  and icon straight out of the image's filesystem. Nothing in it runs until
  you start the app yourself. Found by the automated review in the DMS
  plugin registry.

- **Opening `.appimage` files is your choice.** On first run the plugin
  made itself the default app for AppImages when no other app held that
  file type. It no longer does: the switch is in the plugin settings, off
  until you turn it on. If it was already set, it stays set, and the same
  switch turns it off.

- **The update check for the plugin itself no longer needs curl.** It
  uses the Python the helpers already require.

## 1.3.1 — 2026-09-30

- **AUR development packages can update with everything else.** With
  devel turned on in yay or paru (`yay -Y --devel --save`, or `Devel` in
  `paru.conf`), a `-git` package whose upstream has new commits shows in
  the list as going to "latest commit" and is rebuilt in the same pass.
  Until now the check afterwards looked for a version literally called
  `latest-commit`, and would have marked every one of them as not updated.
  It now checks that a new build replaced the old one, and the log records
  the version it became. Thanks to @qu33rz for asking (#26).

## 1.3.0 — 2026-09-28

Thanks to @bernardopg for #25, which fixed the clipped list outlines, the
filter running under the sort dropdown, the wrapping plugin summaries, the
settings tab contrast and the square search bars; and to @apollo79 for
reporting two of those in #23 and #24.

- **Every tab's list is drawn the same way.** Updates had tinted boxes
  around its categories, where Installed and Install have a plain heading
  over rows. It has the heading now, and that heading stays pinned at the
  top while you scroll through a long category, as it already did in the
  other tabs. Headings and rows start at the same left edge in every tab,
  the source filters sit on the left, and a row rounds to a pill when you
  hover over it on every page.

- **An update row shows the version change, not the summary.** The
  summary is one click away in the details, and the list is about what
  changes. This makes the rows about as tall as the rows in Installed.

- **App icons are sharp and the same size everywhere.** Icons larger than
  their slot, the DMS logo among them, were drawn full size and then
  shrunk without smoothing, which made them jagged. They are now drawn at
  the size shown, and that size is 32px in every list instead of three
  different sizes across three tabs.

- **A pinned heading looks like the heading it replaces** and no longer
  shows up as a grey bar over a list that has not been scrolled.

- **A tab slides in from the side it sits on.** Sometimes it came in from
  the side of the previous switch, and on Updates always from the wrong
  side.

- **The search bars are fully rounded and light up only once you type.**
  A tab still puts the keyboard in its search field when it opens, but the
  field is no longer highlighted before you have touched it. Firmware has
  no search field any more: it lists a handful of devices, with the ones
  that can be updated at the top.

## 1.2.0 — 2026-09-23

Thanks to @JDKamalakar for #21, the visual overhaul this release is built
on. It is taken in part rather than whole — the look, the motion and the
iconography are theirs; the list architecture underneath is back to what
it was, and the surface layering sits at two levels rather than four.
See that pull request for what was and was not taken, and why.

- **A new look, following DMS.** Rounded corners, press and hover
  feedback, per-category icons and animation throughout. Every container
  fill is one value now instead of five, and a box is drawn only where it
  holds something that is not already a box — so a heading groups a list
  rather than a tinted panel inside another tinted panel. The accent
  outline that #21 put on all 71 containers is gone; the ones that change
  under the pointer stayed, because those mean something.

- **The plugin follows the shell's own settings.** Animation timings come
  from DMS's duration scale rather than 366 numbers written here, so the
  plugin speeds up, slows down and stops with everything else — including
  for anyone who has set animation to none. Hover and selection colours
  are DMS's named states, not values that happened to look close. Card
  and chip surfaces follow the colours set in DMS settings where the
  shell offers them, and fall back to what they always drew where it does
  not.

- **Long lists stay fast.** The installed list and the storefront's
  categories and search results build the rows on screen instead of all
  of them, which is how they worked before and how they work again: 1971
  system packages with no "show 60 more" in the way. The row you hover
  rounds the same way on every page, and its outline runs all the way
  round on the first and last row too.

- **"Restart recommended" appears again after a kernel update.** It had
  not since 11 August, and the reason is dated 22 August: that is when the
  action log learned to wait for the post-run verification before writing
  itself, because a row still being confirmed is not a row that failed.
  The reboot notice reads the same per-package states and was left on the
  eager path, so it ran while every row still said "verifying" and none
  said "done" — nothing matched the kernel pattern, and no notice was ever
  raised. It waits for the same answer now. The stale flag a machine may
  still be carrying from before then is ignored, as it always was: the
  notice is tied to the boot it was raised in.

- **A helper that was killed says it crashed, rather than that it could
  not start.** The two arrive down different channels — an exit code and
  an exit status — and only the first was being read, so a helper that ran
  perfectly well until the signal that ended it reported the one thing it
  had not done. That sentence sends a reader to their bindings, which is
  where the first report of this spent a week on a machine whose bindings
  were fine (#18, still open: the crash itself is upstream of the plugin,
  and this is about naming it correctly).

## 1.1.10 — 2026-09-20

- **A package dnf skipped because of a dependency conflict now says so,
  instead of "try again".** An upgrade whose dependencies cannot be
  satisfied — a package from another repository requiring the installed
  version exactly, which is what RPM Fusion's `libheif-freeworld` does to
  `libheif` — is skipped by dnf, which then reports success: skipping was
  what it was asked to do. The row went red on verification, correctly,
  but its reason was an invitation to retry something that resolves to the
  same nothing every time, and its details panel was empty. The solver
  explains itself in its resolve logs rather than in `get_problems()`,
  which stays clean for exactly this case; the helper now passes that on,
  naming the conflict on the row and putting the solver's own report
  behind it. A genuine "everything is already current" logs nothing there,
  so it stays as quiet as it was.

## 1.1.9 — 2026-09-19

Thanks to @bernardopg for reporting #19 and for the fix in #20, and to
@vpedicino for reporting #18.

- **AUR updates no longer fail the whole run on Arch with "package not
  found".** The DMS daemon lists AUR packages as pending updates (its AUR
  backend is paru or yay), but the update run handed every non-Flatpak
  pending package to the pacman helper — which resolves official
  repositories only, so the first AUR package in the list failed the entire
  transaction and every package in the run reported a failure. AUR packages
  now ride the shell pass on the DMS daemon instead, the same pass the
  shell's own packages already travel on: it runs `paru -Syu` (or yay) in a
  visible terminal, exactly the upgrade the shell's own updater performs,
  and the plugin still builds no AUR packages itself. Official-repository
  updates keep the pacman helper's per-package byte progress; the plan
  preview now covers those only, since the daemon pass has no plan to
  preview. Reported with stably-orca-bin on Arch (DMS 1.6.1).

- **A pacman backend whose bindings import but do not work is caught at
  startup, and a helper that dies before it can speak now says how.** The
  startup check asked pyalpm whether it could be imported, which a pyalpm
  built against a different libalpm than the installed one answers yes to —
  it gives way at the first call into the library, not at its import. So
  nothing was said at startup and the fault arrived much later as a run
  where every package failed with "the package helper could not start", a
  sentence whose details panel held a copy of that same sentence and
  nothing else. The check now opens a handle, which is the step that
  actually crosses into libalpm and still needs no root, no network and no
  database lock; and when a helper does end without a word, how it ended is
  kept — a crash and a clean refusal are different faults and a report has
  to be able to tell them apart. This does not itself fix #18, which is
  still open: it is what the next report of it will be able to carry.

## 1.1.8 — 2026-09-11

Thanks to @kmf for reporting #16 and for the fix in #17.

- **Flatpak apps without AppStream data are listed under their whole app id
  again on Debian and Ubuntu.** They were being cut at the first letter `t`
  and the remainder shown as a version — `io.github.kolunmi.Bazaar` appeared
  as `io.gi` over `hub.kolunmi.Bazaar`. The listing read `flatpak list` with
  `IFS=$'\t'`, which is bash syntax: `/bin/sh` is dash there, dash has no
  ANSI-C quoting, and the separator quietly became "any of `$`, `\` or `t`"
  rather than a tab. It is a portable `IFS="$(printf '\t')"` now, and a check
  in CI reads every shell snippet in the QML for bash-only syntax — this class
  of fault produces no error anywhere, only wrong output on one family of
  distributions

- **The bar pill no longer opens and closes the window over and over while
  the pointer rests on it.** DankBar has a "hover popouts" setting, and a
  widget that names a click action gets that action on hover as well — the
  same call, with the same arguments, so there is nothing on this side that
  can tell the two apart. For a widget opening one of DMS's own popouts that
  is fine: it can see that the popout it asked for is up, and stops asking.
  This window is not one of those, DMS never learns it opened, and it asked
  again at every hover tick — against a toggle, which answers open, closed,
  open. With hover popouts on, the pill now only opens; closing it by clicking
  the pill again was never available in that configuration anyway, since every
  click is preceded by the hover that would reopen it. Without the setting,
  which is the default, nothing changes

- **A run can be recorded and played back.** Development only, and invisible
  on a normal install: nothing the window draws comes from the system
  directly, so a recording of the helpers' NDJSON is a recording of everything
  it can show. Playing one back drives the whole interface through a real run
  without root and without waiting for a distribution to ship thirty updates —
  which is what working on the *look* of an update used to require, once per
  set of updates, since installing them is what makes them stop being pending.
  See Development in the README

## 1.1.7 — 2026-09-03

Thanks to @Tartuffe-X for reporting #15 and to @JDKamalakar for #14.

- **New setting: authorise with sudo.** Off by default. A machine where sudo
  has been made passwordless was asked for a password anyway (#14) — not
  really a bug, but two authorisation systems: a `NOPASSWD` line is a rule in
  sudoers, and `pkexec` asks polkit, which has never heard of it. With this on,
  privileged commands run under `sudo -n` instead. It cannot hang: `-n` never
  prompts, and the command checks whether sudo would answer before handing
  itself over, so narrow sudoers rules — or no sudo at all — fall back to the
  polkit prompt and end up exactly where they were. The shell's own packages
  still go through the DMS daemon and firmware still goes through fwupd, each
  with its own polkit action, so those keep asking. The plugin's eight
  privileged call sites now build their command in one place rather than
  writing `pkexec` out eight times

- **The Flatpak requirement no longer asks for a package that is already
  there.** PyGObject and the Flatpak typelib are two separate things, and only
  one of them was ever named on Fedora and Arch: a machine whose typelib was
  missing — it comes with `flatpak` itself, so a system without Flatpak has
  none — was told that `python3-gobject-base` was missing, on a system that
  had it, and installing it again could not change the answer. The helper now
  says which half it could not load and the banner asks for that one
- **A system without Flatpak is no longer treated as a broken one.** There is
  nothing there to update and nothing to fix, so the requirement is not shown
  at all rather than as a warning nobody can act on
- **Installing the Flatpak bindings from the banner re-checks the Flatpak
  helper.** It re-ran the *package* helper's check instead, so the warning
  stood over a system that had just fixed it — "clicked Install, nothing
  changed" — until the shell was restarted. A check asked for while one is
  running is also no longer dropped, for the same reason it is not dropped for
  the package helper
- **A pyenv or virtualenv interpreter with a pip-installed PyGObject hands the
  command over again.** The hand-over to the system interpreter asked only
  whether `gi` could be imported, which a pip copy answers yes to while
  bringing no typelib with it, so the command stayed in the one interpreter
  that could not finish it. It now probes what the helper actually needs, and
  hands over at most once

## 1.1.6 — 2026-08-26

Updates felt slower through this window than through dnf in a terminal. The
transaction was not slower; everything around it was — and looking into that
turned up a refresh that had never refreshed anything.

- **Every system transaction now revalidates the repositories**, which is a
  change for everyone and the reason for the rest. The helper was supposed to
  do this already: it set `metadata_expire` to 0 so a transaction could not
  resolve against a stale view. It never could — every Fedora repository file
  carries its own value (6h for updates, 7d for fedora, 14d elsewhere) and a
  repository's own value wins over the main one. So a package updated between
  the last expiry-driven refresh and the run resolved to *nothing to do*,
  silently, for the whole run. It expires each repository before loading now,
  which is what `--refresh` does. Expect a second or two per run when nothing
  has changed, and more on a slow connection
- **A package with no candidate says so.** "The repositories offer no newer
  build of: …" rather than leaving the check afterwards to report packages as
  not updated with nothing behind it
- **The end of a run no longer waits on a metadata refresh.** Confirming that
  the packages really are at their new version used to mean triggering a
  daemon check — `dnf5 check-update --refresh`, a full revalidation, at the
  end of every run, into a different cache than the one the transaction just
  wrote. rpm answers the same question from the database the transaction
  changed, in milliseconds
- **No more phantom "N updates available" when a run finishes.** That check
  published a list still holding the packages the run was installing, and they
  were announced as news. Suppressed while a run is going and for thirty
  seconds after — bounded by time rather than by the result panel, so a failed
  run left on screen does not silence updates for the day
- **System packages and the shell's own packages are separate passes again.**
  Folding them together bought one polkit prompt instead of two, on the
  assumption that runs containing DMS packages were rare; on a machine
  following dms-git they are nearly every run, and that assumption had cost the
  per-package byte progress and forced a refresh on everything. A run touching
  both kinds asks twice now

## 1.1.5 — 2026-08-24

- **Flatpak updates that libostree refuses are pulled the long way instead.**
  libostree 2026.3 caps how large a decompressed delta part may be — a guard
  against decompression bombs, set too low — so an app whose delta crosses it
  cannot be pulled at all: *"While pulling app/… from remote flathub:
  Decompressed delta part exceeds configured limit of 67386875 bytes"*. It is
  a libostree regression, fixed in 2026.4, and by upstream's own account
  nothing Flatpak itself can do about. But the update is fine; only the
  shortcut is broken. An operation that hits the cap is now retried once with
  static deltas switched off — the whole objects instead of the difference,
  more bytes for the same result, which is what `flatpak update
  --no-static-deltas` does by hand. Installing takes the same way around it
- Neither the failure nor the retry is reported as a failed update, because it
  is not one. It is said out loud in the event stream, and a row that fails
  for a different reason is still reported the moment it does
- The Flatpak path has tests now, run against a stand-in for libflatpak that
  can fail on cue — the real case needs an app whose delta happens to be big
  enough, which is not something a machine can be asked for

## 1.1.4 — 2026-08-24

Thanks to @qu33rz for reporting #13.

- **Updating system packages on Arch works.** The transaction resolved package
  names against the sync databases exactly as they sit on disk, and nothing in
  this plugin ever refreshed them — while the list of pending updates comes
  from `checkupdates`, which refreshes a private copy of those databases and
  throws it away. So the list was right, the transaction was resolved against
  yesterday's answer, libalpm replied "is up to date -- reinstalling" for every
  package, and the check afterwards correctly reported that nothing had reached
  its new version. The databases are refreshed before a transaction now
- **A package already at the version the repositories offer is left alone**,
  which is what pacman's own `--needed` does and what the daemon's `pacman
  -Syu` has always used. Those reinstall-the-same-files lines are gone
- A failed refresh — one unreachable mirror — is a reason to attempt the
  transaction with what is on disk, not to refuse it, and the reason travels
  with the result either way
- The Arch path now has a test, run against a stand-in for pyalpm, so it is
  checked on machines that have neither pacman nor Arch — which is every
  machine this plugin is developed on

One thing to know on Arch: updating a *single* package refreshes the databases
first, which makes it a partial upgrade — the thing Arch tells you not to do.
Update All sends the whole pending list and is the safe path. Arch support is
still marked experimental for reasons like this one.

## 1.1.3 — 2026-08-23

Thanks to @pdf for both reports.

- **"Hide when up to date" works.** It never has, for anyone, on any
  distribution: the pill expressed its visibility by binding a host property
  that the host only reads when the plugin also supplies a shell command to
  decide visibility — and with none supplied, the host assigns that property
  itself, destroying the binding. The pill now tells the host directly (#12)
- **The readiness banner is about your package manager.** On Arch, the first
  window after a boot could carry a banner headed "pyalpm could not be loaded"
  over a line about python3-libdnf5, on a machine with pyalpm installed. The
  check runs at startup while the backend is still assumed to be dnf, and the
  re-check that follows once `/etc/os-release` has been read was being dropped
  rather than deferred, because the first one was still running. The same
  fault could also hide a genuinely missing binding, when the wrong probe
  happened to succeed. Atomic Fedora was affected by the same race (#11)
- **A package that fails with nothing to show for it now shows something.**
  When the update service reports a pass as clean and the packages are not
  there, it hands over no error — so the details panel was empty. The last of
  what the service said goes in there instead

## 1.1.2 — 2026-08-22

A log entry saying three packages over a list of thirty-seven, thirty-four of
them marked unfinished while every one was on disk. Two faults, both of them
in the commit that was supposed to have fixed this in 1.1.0.

- **The replay that heals a torn-down run asked the wrong question.** After a
  DMS update reloads the shell, the entry is written again and checked against
  the package database. That check was widened to cover every row the run did
  not see finish — but the list of names actually sent to the database still
  only collected the rows that had *failed*. So the pending rows were healed
  against an answer nobody had asked for, and stayed pending forever
- **The log was written before the verification could answer.** A run ends by
  moving every system and Flatpak row into "confirming", starting the pass
  that checks the packages are really no longer offered, and then emitting
  finished — which is where the log entry was written. It recorded that
  moment: a grey clock next to a package that installed perfectly, on any run
  at all, no shell reload needed. The entry now waits for the answer, which
  also means a package the check still finds pending arrives in the log as the
  failure it is rather than as a success
- Existing entries are not rewritten automatically — a log is a record, and
  this one silently repairing itself is a worse habit than the bug. If yours
  has grey clocks on packages you know landed, they are wrong about the past
  and right from here on

## 1.1.1 — 2026-08-21

Thanks to @kmf for reporting #10.

- **Homebrew formulae no longer call themselves system packages.** One mapping
  from a row to the name of its source had been written out in four places,
  each copy with a different hole in it: the update card knew Flatpak and DMS
  plugins, the action log knew four kinds, the details popup knew three, and
  none of them knew Homebrew. Everything that fell through said System — so
  AppImage and firmware rows were quietly saying it too. There is one now,
  used by all four
- **The details popup for a formula stops asking the system about it.** It was
  offering a dnf source for something that lives in brew's own prefix, and
  asking the package manager for the changelog of a package it never installed
  — which is what left *Loading changelog…* on screen for good. It is filled
  from brew instead: version, licence, homepage, dependencies and installs
  last month, the same panel the Install tab shows
- **Rows are named by the name meant to be read**, so the list no longer says
  `charmbracelet/tap/crush` where the popup one click away says `crush`
- **The source chip is gone where the heading above already says it** — under
  System packages, Firmware, Homebrew and DMS plugins it was the heading again
  in smaller type. It stays under Applications, which holds Flatpaks and
  AppImages together, under Held, which holds anything, and during a run,
  where the groups are In progress and Waiting and the chip is the only thing
  saying what a row is
- **Section headings stay put while you scroll**, in all four lists: which
  group you are in, which day of the log you have reached, which storefront
  category you are hundreds of rows into. Worth more now that the rows beneath
  a heading no longer each repeat it
- The bug report form has boxes for Homebrew and DMS plugins, which is why
  #10 arrived with none of them ticked

## 1.1.0 — 2026-08-19

Homebrew becomes somewhere you install *from*, not only a section that gets
updated — and with it the round of corrections that a day of actually using
1.0.0 turned up.

- **Install from Homebrew.** Brew joins the Install tab the way Copr did,
  because it poses the same question: a catalogue this machine keeps and this
  storefront does not index. So it is one deliberate press at the end of the
  results rather than a search per keystroke, and only where brew exists. The
  search goes through brew's own copy of the index rather than fetching the
  30 MB document again; opening a result shows what brew knows — version,
  licence, homepage, dependencies, and how often it was installed in the last
  thirty days, from Homebrew's own analytics. **Homebrew grew up on macOS**,
  and its core still carries formulae that cannot run here: those are listed
  greyed with the reason rather than dropped, because "this exists, but not
  for you" is an answer and silently returning nothing is not
- **A Homebrew chip** in the Install tab's filter, next to the Copr one, each
  appearing only on a machine where it means anything. Picking one narrows the
  offer to search elsewhere along with it — an offer whose results the current
  filter would throw away is worse than no offer
- **The stepper stops running ahead of the work.** During the Flatpak phase it
  would move to Install while rows underneath were still counting up download
  percentages: several refs install at once, and the first to get there moved
  the whole stepper. It is a statement about all of them now. The DMS package
  pass no longer reads as Install through the minutes it spends downloading,
  and the AppImage phase no longer reads as Download while it writes the
  desktop entry. Firmware, Homebrew and the plugin pass are deliberately left
  as they were: a step that is wrong in a new way is not an improvement on one
  that is wrong in a known way
- **The strips on the Updates tab moved below the tab bar.** Pending updates,
  a manual pass, end-of-life components, a newer Fedora, unread Arch news —
  all five used to push the tabs down as they appeared and let them spring
  back when you switched tab, which is precisely when you are aiming at one.
  The header and the reboot banner stay above, because the reboot notice is
  true wherever you are
- **Update All lands at the top of the list**, instead of somewhere in the
  middle of it: the jump ran in the same instant the dashboard header left and
  the run's own rows arrived, so the content moved out from under it
- **Progress bars stop replaying finished downloads.** A card scrolled back
  into view animated its bar from zero again, which is what made scrolling
  during a run feel busy
- **The log tells three outcomes apart.** A row that never finished is drawn
  as unfinished rather than as a success — an entry could say "2 packages
  updated" over three green ticks. Behind that: the replay that runs after a
  DMS update reloads the shell now re-checks every row it did not see finish,
  not only the ones it saw fail, so a package that went in during the reload
  stops being pending forever; and it can no longer write an entry with
  nothing in it
- **The item-count chip is gone** from the right of every log entry. It
  repeated the number already in the title, and on the entries where it did
  not, what it had to say was one click away in the entry itself

## 1.0.0 — 2026-08-19

**1.0.0 is where the numbering arrived, not a claim that this is finished.**
It is the same software as 0.9.9 with Homebrew added; it is still in beta, it
still changes quickly, and the status section of the README still says so. If
you were waiting for a version number to mean "safe now", keep waiting — what
it means is that thirty-five releases came before this one, the first of them
on 5 August, a fortnight ago.

Thanks to @kmf for asking for Homebrew.

- **Homebrew support.** On a machine that has brew, its formulae are a kind of
  software this window manages: their own section in Updates, their own group
  and filter in Installed, a line on the dashboard's installed-software card,
  a place in the bar pill's count, and their own phase in Update All. Brew
  needs no privileges, so this asks for nothing — no password, no polkit, no
  daemon. It reports no machine-readable progress either, so a formula goes
  from active to done rather than filling up, and the phase says out loud that
  a formula without a bottle is compiled from source and can take a while. A
  pinned formula is brew's word for held and is left alone. `brew update` is a
  git fetch, so the formula index is refreshed at most every six hours rather
  than on every check.

  **Tested against a real Homebrew, in a basic setup**: installed, a formula
  taken from one version to the next, upgraded through this window, confirmed
  by brew as no longer outdated. That is the extent of it — the author does
  not run Homebrew day to day, so nothing here has met a large installation,
  a machine that leans on taps, or a formula that takes twenty minutes to
  compile. If you do run brew and something reads wrong, the issue tracker is
  the fastest way to have it fixed.
- **The phase stepper stays for its own last two steps.** Verify and Done were
  both on the stepper and neither was ever on screen: the panel around it hid
  itself during verification, and the stepper hid itself once the run was
  done.
- **A result card that clears itself says so first.** A finished run with
  nothing to report clears its panel after a few seconds; a line now runs out
  along the bottom edge for exactly that long, so the card leaving is
  something you watched approach. It does not count down when the panel is
  staying — during a run, or after one with a failure to report.

## 0.9.9 — 2026-08-18

- **Three numbers for one thing, and two of them wrong.** The header counted a
  package the daemon names twice — it does that when two enabled repositories
  carry the same one — while the list below it had always collapsed those. And
  the transaction line counted both halves of every upgrade, since libdnf5
  resolves one into the new package arriving and the old one being replaced:
  three updates were summarised as six packages. All three places agree now.
- **The up-to-date mark, the DMS penguin and the pulse follow the theme.** The
  mark was the only green thing on a dashboard that is otherwise the accent,
  the penguin the only untinted one, and the pulse was drawn in two colours,
  which made one wave read as two marks chasing each other. A failed check
  keeps its red, where the colour is the message. Light mode is unchanged
  there: the disc behind the mark is already the accent, with the mark white
  on top of it.
- **Buttons that are the only thing to do no longer look like the second
  choice.** Open, Write a review, the two at the foot of the settings dialog
  and the one that opens this window from DMS Settings all wore the muted tone
  this app uses for the alternative in a pair. They take the accent, which
  also means they follow the button-colour setting. What keeps the muted tone
  is the alternative install source, where it means what it says.
- **App icons are tinted with the theme colour by default.** The switch stays
  for anyone who prefers each app's own artwork; turning it off keeps it off.
- **Smaller things.** The Recently updated card no longer labels every row
  with where it came from — the log answers that per entry, in a view built
  for it. A plugin's "Manage plugins" button moved out of the middle of the
  facts it was interrupting, to the row of actions at the bottom.

## 0.9.8 — 2026-08-18

Thanks to @BadLemon5267 for catching the first one within a day of it going
out.

- **Fixes 0.9.7, which could not be enabled at all on DMS 1.5.x.** The window
  was rebuilt on DankFloatingWindow, which is what DMS uses for its own
  windows — and which arrived upstream after 1.5.3. A QML file naming a type
  that does not exist does not fall back to something simpler; it fails to
  load, and takes the widget and the whole plugin with it. The window asks for
  the colour by name again instead of inheriting the component that has it,
  and falls back to the tone that colour is derived from where it is missing.
  The background still matches DMS on a shell that is new enough to have one
  to match.
- **One password per update run.** A run carrying DMS's own packages asked
  twice, which is why it seemed to come and go: the ordinary packages go
  through a helper under pkexec and the DMS ones through the daemon, because
  that transaction has to outlive the shell reload it causes, and those are
  two different polkit actions. When the shell's packages are in a run, all
  system packages now travel with them in that single daemon transaction.
  Runs without them are unchanged and were never the ones asking twice.
- **The up-to-date mark and the DMS penguin follow the theme** instead of
  being the only green and the only untinted thing on the dashboard. A failed
  check keeps its red, where the colour is the message.

## 0.9.7 — 2026-08-17

Thanks to @gitblit for the report and the screenshot behind this one.

- **The window uses the theme's own background, like the rest of DMS.** It
  reacted to theme changes and stayed within the spirit of the palette, but it
  painted a surface of its own choosing, which read as slightly out of place
  next to DMS Settings. It is now built on the same floating window the shell
  uses for its own: the same background tone, the same rounded corners, the
  blur behind it, and the border the shell gives every floating window. It
  also follows the floating-window transparency setting, which it used to be
  deaf to.

## 0.9.6 — 2026-08-14

- **Installs that failed, and installs that happened quietly, are in the log
  now.** Only successful installs were recorded, and only the ones made from
  the Install tab. A failed one said so in a line at the bottom of the view
  that is gone the moment you navigate away; it is kept now, with its reason
  and the tool's own words, the way a failed update run always has been. The
  bootstrap installs — the package-manager bindings, the AppStream catalog —
  never appeared at all, because they skip the transaction helper by design
  and skipped everything that would have recorded them with it. That also
  means they will stop turning up later as packages that "changed outside
  this app": that card compares install times against this log, so anything
  this app did without writing it down came back as a stranger.
- **"No results" no longer flashes before the results arrive.** Searching for
  something only the package-name fallback can find — libheif, which no app
  catalog describes — put "No results" on screen for the second that fallback
  takes to answer. The empty state now asks whether anything is still coming
  rather than whether the list is empty, and the offer to search Copr waits
  with it. Results the local index already has still appear immediately.
- **A version is shown in full again in the log.** The field holding
  `old → new` capped its own width with a measurement of itself, which came
  out short: an update from 8.1.4087.64-1 to 8.1.4087.66-1 lost its arrow, and
  a plugin at 4.2.1 was rendered as "4…1". A plugin's line also had nothing to
  the right of the arrow, since the plugin manager reports that a newer build
  exists but never which version it is; the entry now reads that off the
  manifest once it is on disk.

## 0.9.5 — 2026-08-13

- **Holding a package, and releasing it, are recorded in the log.** Everything
  else this app does ends up there; locking a package did not, so the list
  quietly stopped counting something one day and a month later there was
  nothing to say why, or that it had been a decision at all. The release is
  the half that earns its keep: an update you have been waiting for, which
  turns out to have been sitting behind your own lock, is now a question the
  log can answer.
- **Tinted icons are calmer in light mode.** The same accent arrived in very
  different amounts in the two palettes: in dark mode only an icon's
  highlights come out accented, while in light mode the lift that keeps shapes
  from collapsing moves most of the icon into the accent, so a card carried a
  large block of fully saturated colour. Not less lift — the shapes need it —
  but a quieter colour to lift into, at 55% saturation. Dark mode is
  unchanged; it was already the picture the other one is tuned towards.

## 0.9.4 — 2026-08-13

- **The action log follows the interface language.** Every line was written as
  a finished sentence, translated at the moment it was recorded, so the log
  was a record of which language the interface had been in that week: switch
  to English and yesterday's runs stayed in Dutch. Entries now record what
  happened rather than the words for it, and the sentence is put together when
  it is read. Lines written before this keep the language they happened in —
  the words were all that was saved, so there is nothing to translate them
  from.

## 0.9.3 — 2026-08-13

- **The About popup links to the changelog.** It named the version and offered
  no way to read what that version means; the only link went to the front page
  of the repository, which is not where the file is.
- **The shell's own packages carry DMS's logo.** `dms`, `dms-cli`,
  `dms-greeter` and `quickshell` have no AppStream entry and so no icon, and
  fell back to the chip glyph every package without artwork gets — in a list
  where they are the entries that reload your desktop when they install, which
  is exactly where a recognisable mark earns its keep. It is a fallback rather
  than an override, so anything with an icon of its own keeps it.

## 0.9.2 — 2026-08-13

- **A plugin in the action log was recorded as if it were a package.** It said
  System, where it should say DMS; it could not be clicked, because the entry
  was written without the id the log uses to lead back to what it is about,
  and the fallback guess — a package name has no spaces in it — does not hold
  for "Quick Capture"; and opening one would have produced the package popup
  that 0.9.1 taught not to appear for plugins, since the log kept its own copy
  of that distinction. Entries written from here on carry the id and the
  source; the ones already on disk are read as the plugins they were.
- **The dashboard counts plugins** among the installed software, in the total
  as well as in the rows.
- **The DMS version is on the System card**, next to the OS, the host and the
  kernel. Everything here runs inside that shell and through its daemon, and
  it is the version somebody needs when reporting that something misbehaved —
  taken from the daemon's own handshake, so it is the one actually answering.

## 0.9.1 — 2026-08-13

- **DMS plugins are the fifth kind of software this window manages**, and the
  only one that lives in the shell running it. The daemon already knew which
  installed plugins the registry has a newer build of — the flag Settings →
  Plugins counts its own "Available Updates" from — so they now appear in
  their own section of the Updates tab, count towards the bar pill, and update
  in their own phase of Update All, one at a time. There is no byte progress
  to be had from the plugin manager, so those rows go from active to done
  rather than filling up, which is what the firmware phase already settles
  for. This plugin leaves itself out of that phase: it offers its own update
  from its own release notes, and replacing the code running a transaction,
  during the transaction, is the case the DMS packages get a final pass for.
- **Installed has a plugins group** beside Applications and System packages,
  read from the manifests on disk, with the plugin's own icon — a manifest
  names a Material Symbols glyph rather than shipping an image — a filter chip
  to see only those, and a button in the heading that opens DMS's own plugin
  screen. The Install tab gets the matching button next to the AppImage one.
  Installing and removing plugins stays where it already worked; this window
  reports on them and updates them.
- **A plugin's details show what a plugin has.** Opening one used to produce a
  System chip, Fedora as the source, "Full system access · built by Fedora"
  and a changelog reading "package quickCapture is not installed" — every line
  of it from asking rpm about something rpm has never heard of. It now shows
  the author, the category, whether it is installed for you or for everyone,
  the directory it sits in, and the permissions it declared to the shell, as
  the same chips a Flatpak's sandbox permissions get. The source chip says
  DMS, and the buttons that would have handed a plugin id to the package
  manager are gone.
- **The hint in a text field stays while the field is empty.** Clicking into
  one used to remove the sentence explaining what belongs in it, at the moment
  someone was deciding what to type. All eleven fields keep it now.

## 0.9.0 — 2026-08-13

- **One Install button, and a straight answer behind it.** An app carried
  by both Fedora and Flathub used to put a button for each in the row and
  leave you to know the difference. Now the row asks once and opens a
  picker: the sources side by side with the version, the download size,
  whether it is sandboxed and how many permissions it has, and who stands
  behind it — the distribution, a verified publisher, or one person on
  Copr. Under that, a paragraph on what each kind of packaging gives you
  and what it costs. A single source still installs with one click.
- **Which source you already have** is marked on the source itself. The
  chip at the top said "Installed" without saying which of the two it
  meant, which is the one thing worth knowing before touching anything.
- **Honest about what it cannot compare.** VLC is 188 kB as an rpm and 53
  MB as a Flatpak — Fedora splits the package, the Flatpak carries its
  own libraries, and neither number counts what it drags in; the popup
  says so rather than implying a comparison. Versions are compared on
  their leading digits only, since `3.0.23` and `3.0.23-10.fc44` are the
  same release, and on a tie nothing is marked newest.
- **App icons can follow the theme.** Off by default, under Plugin
  settings: icons are drawn in the active DMS accent instead of their own
  colours. Tuned separately for light and dark mode, because the effect
  maps an icon's own brightness onto the accent and that lands very
  differently on a light card than on a dark one. Packages with no icon
  of their own follow it too.
- **The Install tab stops showing what you already installed.** That is
  what the Installed tab is for. Searching still finds them, with the
  Installed marker — being told an app does not exist because you have it
  would be worse than showing the row.
- **The Reclaim space card no longer vanishes mid-use.** It offers two
  piles, and clearing the larger one used to drop the total under the
  threshold that made the card appear, taking the second button with it.
  Cleared rows now stay, ticked off, until you leave the window.
- **Review stars use the theme accent**, like the buttons already did.
- **Both settings panels offer the same settings.** The window's own
  panel and the plugin page in DMS settings had drifted apart; automatic
  updates and the launcher entry have joined the latter.

## 0.8.3 — 2026-08-13

- **The Install tab is something you can walk through now.** Every heading
  opens, and behind it is the whole section rather than the six apps that
  fitted on the storefront: Games is 892 apps here, Utilities 750. Chips
  at the top of a section say where else to go, rows arrive as you scroll,
  and typing inside a section searches all of it — not the part you have
  scrolled past. Sections are cut from the search index instead of being
  a second, shorter list sent alongside it, which is what makes "all of
  it" and "searchable in full" the same thing rather than two promises.
- **Thirteen sections instead of eight**, from Flathub's own top-level
  categories: Education, Science, Health & Fitness and Internet are new,
  and whatever fits nowhere lands in Other rather than being dropped. On
  this machine that last one holds 46 apps, 39 of which carry no category
  at all — until now they could be found by name and by nothing else.
- **Sorted by downloads.** That number did not exist in the app before;
  "popularity" meant review volume, which is a much smaller and different
  thing. Flathub's install figures for the last month now decide the
  order, refreshed daily. Two honest limits: only software Flathub
  carries has such a figure, so an rpm with no Flatpak sorts last with
  review count standing in; and the figures cover the top thousand, which
  makes absence "fewer than the smallest number here" rather than
  unknown. Reading them never waits on the network — the storefront takes
  what is cached and a refresh happens out of sight.
- **"Search Copr" exists again**, and sits under the results instead of
  above them, which is where "not here?" is a question you have just
  arrived at. It had been invisible since 0.8.0 — a wrapper added around
  the button to fix its width asked the button whether to be shown, and a
  parent asking that of its child has already decided the answer.
- **Two more buttons that had gone the same way**: "View in log" after a
  failed update, and "Save" on an AppImage's update source. Both were
  noted a fortnight ago as things that *could* latch and left alone;
  both had already latched, because both live somewhere that starts
  hidden.
- **Typing stays quick on a four-thousand-app catalog.** A query that
  grows is matched against what survived the previous letter rather than
  against everything, and the tab warms up shortly after the window opens
  instead of on the click that asks for it — that click is usually
  someone about to type.

## 0.8.2 — 2026-08-13

- **Release notes you can read, and now actually select.** This plugin's
  own notes were the smallest text in the app — 12px in the banner that
  offers the update, 11px in the About window — on the one banner that
  asks to be acted on. Both are 14px now. They were also made
  selectable last week and still could not be selected: they sit in a
  bounded scroll area, a drag inside one is a scroll, and a scroll and a
  selection are the same gesture until one of them claims the mouse. The
  viewport won every time. It no longer takes the drag, and the wheel
  and the scrollbar carry on as before.
- **A licence long enough to push the close button off the card.**
  Fedora hands out whole sentences as licence ids, and
  `LicenseRef-Callaway-Redistributable-no-modification-permitted` is a
  single unbreakable word: nothing to wrap on, so it ran past the edge
  of the details popup. Worse than the untidiness, the width it claimed
  was claimed by the column it sits in, which is followed in the header
  by the × — so the button left the card. The licence now takes the
  width that is left over instead of asking for its own, and breaks
  mid-word when a word does not fit.

## 0.8.1 — 2026-08-12

- **A run is over when the check says so.** Every run ends by asking the
  daemon to check again, and that check was doing its work behind a list
  that already said Completed — minutes of it, with only the counter in
  the header to show for it. Finished items now wait in a **Confirming**
  group, the stepper has a **Verify** step and pulses on it, and nothing
  claims the system is up to date until it is known. What makes that
  worth more than a nicer spinner: a package still offered as an update
  after its own transaction reported success did not take, and instead
  of quietly reappearing at some later check it is now marked on the
  card, with the reason, and counted among the failures.
- **The details popup opens straight away.** It was consulting the
  AppStream search index to decide whether a package is in the catalogs
  at all, and consulting that index means building it when the catalogs
  have moved — which they do when appstream-data comes down with an
  update. The bill therefore landed on whoever opened a popup first
  after updating: measured here, 13.7 seconds in front of a spinner. The
  index is now built out of sight, and the same popup paints in under a
  second.
- **Arch Linux news**, on the distribution that publishes it. Arch
  announces in prose, before the fact, that an update needs a hand — a
  key imported, a package replaced before the rest will resolve. A
  banner appears only when something unread has appeared, and the first
  fetch on a machine marks the backlog read rather than opening with
  eleven interruptions nobody missed. Items are kept rather than
  mirrored, so Ctrl+K → Arch Linux news still has the announcement that
  explains the state this machine is in, long after it scrolled off the
  feed.
- **Text worth copying can be copied.** The CVE numbers in an advisory,
  a changelog, the verbatim output behind a failed update, an app's name
  and its `old → new` version step: all readable, none of them
  selectable. They are now, along with release notes, descriptions and
  announcements. Not every label — the element that can be selected
  takes the mouse with it, and a card whose title was selectable would
  stop being a card you can click.
- **A licence is free text, not a vocabulary.** Vivaldi's package says
  its licence is "Multiple, see https://www.vivaldi.com/", and as the
  third item in a dot-separated line that read like an unfinished
  sentence. The licence now sits behind a mark that says licence, and
  the version step behind one of its own, so any value at all reads as
  what it is.
- **Gaps that were nobody's spacing.** The drive icon on the sizes line,
  and the trend icon on the Flathub install counts, sat half a row away
  from their own sentence: neither the icon nor the text asked for the
  leftover width, and a layout with no taker splits the slack evenly
  between its items.

## 0.8.0 — 2026-08-11

- **A GPG key is no longer reported as a package that changed behind your
  back.** rpm keeps every imported repository key as a pseudo-package
  called `gpg-pubkey`, install time and all, so adding a Copr or RPM
  Fusion made the log's "changed outside this app" card announce two
  strangers — in a card whose entire purpose is to be trusted when it
  does go off.
- **Four buttons stood outside their own margin.** DankButton sizes
  itself by writing `width`, which a layout does not read, so a row
  believed its buttons were nothing wide and put the last one past the
  edge. Reported on the AppImage dialog's Replace button; the same shape
  was then found and fixed for "View in log", "Search Copr" and the
  Save button of an AppImage's update source.
- **The pulsing badge stays sharp.** Its SVG was rasterised at exactly
  twice the drawn size, which the pulse then blew past by a tenth — the
  logo was softest at the peak of every breath. It now asks for what the
  peak needs, at your display's scale. The icon that stands in for the
  logo on hover gets the treatment the spinning bar icon got long ago:
  glyphs hinted to the pixel grid do not survive being scaled.

## 0.7.9 — 2026-08-11

Both fixes in this release come from reports by @kmf — thanks for the
screenshots and the follow-up, which is what made the causes findable.

- **The privileged helper no longer runs whatever `python3` means on
  `PATH`** (#3). The commands were built as `pkexec python3 …`, and pkexec
  resolves that name through `PATH` — so with Homebrew, pyenv or conda
  ahead of `/usr/bin`, the interpreter elevated to root was one the user
  can write to. The system interpreter is now resolved once at startup and
  named by absolute path everywhere, privileged and not.
- **Missing Flatpak bindings are reported before a run fails** (#2). The
  helper needs PyGObject *and* the Flatpak typelib, which are two
  packages, and on Debian and Ubuntu `gir1.2-flatpak-1.0` does not come
  with `flatpak`. The startup check now asks the Flatpak helper as well,
  and a missing binding appears in the requirements card with its own
  wording and an install button naming the packages for your
  distribution — `gir1.2-flatpak-1.0` and `python3-gi` on Debian,
  `python3-gobject-base` on Fedora, `python-gobject` on Arch.
- A requirement can name more than one package now; the install command
  passed it as a single argument, which would have looked for one package
  with a space in its name.

## 0.7.8 — 2026-08-10

- **The last year, on the dashboard.** A card that reads a year back out
  of the action log: how much went through here, across how many update
  runs and how often that works out at, the longest stretch it stayed
  quiet, the biggest single run, the busiest month, and the package you
  update more often than any other. It is counted from the log itself,
  so it says how far back that log actually reaches rather than
  presenting six weeks as a year — and it stays away entirely until
  there is a stretch worth looking back over.
- **The log is kept for two years** instead of ninety days, which is
  what gives the card something to read. About 40 kB a week of ordinary
  use, so a few megabytes over the two years.
- **Security fixes are graded.** The distro says whether a fix is
  critical, important, moderate or low, and that was being fetched and
  thrown away — every one of them read simply "Security". The chip now
  carries the grade, and only the top two are drawn in full red; if
  everything shouts, nothing is heard. The CVE numbers appear in the
  details popup, and the summary line says how many of the pending
  updates are security fixes.
- **A hold on top of a security fix now says so.** Holding a package
  back is a reasonable thing to do, right until the update being held is
  the one that closes a hole. The "Held" and "Security" chips used to
  sit side by side on the same card and leave you to notice; the card
  says it in words, and the summary line counts how many security fixes
  are being held back.
- **What changed without you.** The package database knows when every
  package last arrived, this log knows what this app did, and the
  difference is something else — a terminal, an automatic-update timer,
  another software centre. The Log tab says how many packages that is
  and on how many occasions, expanding to names and dates. Packages that
  came along as dependencies of something you did install count as
  yours, and nothing before the log's own first entry is counted at all,
  because there is nothing there to compare against.

## 0.7.7 — 2026-08-10

- **Double-click an AppImage and it opens here.** On by default, so a
  downloaded AppImage lands in this window instead of nowhere — a fresh
  download is not
  executable, so double-clicking it normally does nothing at all. The
  image is read before anything is offered, from a temporary copy so
  your file is left exactly as it was, and the question matches what it
  turns out to be: install this, or replace the build you already have.
  Which one it is comes from the name inside the image rather than the
  file name, because a download is called `Foo-1.2.3-x86_64.AppImage`
  and the app is called Foo. Installing from a file or URL and this both
  use the same dialog now, instead of a row wedged into the toolbar and
  a card above the results. The association is claimed once and only
  when `.appimage` is going spare — another app already holding it was
  somebody's choice and is left alone — and *Open .appimage files with
  this app* in settings takes it back or hands it over at any time.
- **The launcher entry did nothing when you clicked it.** It called
  `dms` by name, and a launcher hands a program the session's `PATH`,
  not the wider one a terminal builds — and `dms ipc` needs `qs` on it
  as well. Worse, `dms ipc call` exits successfully even when it reached
  nobody, so nothing anywhere said so. The entry now runs a small shim
  that looks in the usual places, treats any answer as the failure it
  is, and puts the reason in a notification. An entry from an older
  version is rewritten by itself the next time the window opens; there
  is nothing to redo by hand.
- **A package that finished installing said so at once, with all the
  others.** Each package reports its own completion and that was thrown
  away, so a run of two hundred kept every row under "In progress" with
  its progress bar full until the verification pass at the end moved
  them all together. Rows now move to Completed when their own install
  finishes, and the verification still has the last word.
- **The date beside a release heading was barely readable in dark
  mode.** The update banner rendered its headings once and baked that
  moment's colours into them, while the text around them kept following
  the theme — so switching to dark left the date a light-mode grey on a
  dark card. The notes are derived now, and follow the theme like
  everything else.
- **A check pulses around the logo instead of spinning over it.** The
  Dank penguin used to be replaced by a rotating arrow for the seconds
  you were most likely looking at it. It stays, and the two rings from
  the shell's own System Check page pulse around it.

## 0.7.6 — 2026-08-10

- **Packages built from git now have release notes too.** A package from
  a `*-git` Copr, or an AUR `-git` build, carries a commit count and a
  short hash where a release number would be — so AppStream has no
  release to describe and the rpm changelog records only the rebuild.
  The details popup was emptiest for exactly the packages that change
  most. It now asks the upstream repository, which the package itself
  names in its URL field. Updating to a tagged release shows that
  release's published notes, plus any release skipped on the way there
  if the version being replaced was a release as well. Updating from one
  build of a branch to another shows the commits in between instead,
  newest first, without the merge commits that name the same changes
  twice. There is a line to the release or comparison page for the rest.
- **What upstream wrote is still not allowed to be markup.** Release
  bodies go through the same reduction as AppStream notes and a little
  further: embedded HTML is dropped rather than displayed as its own
  source, tables are left out where there is one column to draw them in,
  GitHub's `> [!NOTE]` is named instead of quoted, and links keep their
  words and lose their target. Notes running to several screens are cut
  at a block boundary, never mid-sentence.
- **A package that is not built from git never reaches the network.**
  The version decides that before any request is made, so this costs
  nothing on ordinary updates. Answers are kept for a day; a failed
  lookup is not kept, because a moment without network should not mean a
  day without notes.

## 0.7.5 — 2026-08-10

- **Copr is searchable from the Install tab.** A package built in Copr is
  invisible to dnf until its project is enabled, so it could never turn
  up in a search — you had to know the Copr to find the package that
  would have told you about it. There is now a "Search Copr" button
  under the search field: one deliberate press, because it asks the Copr
  hub rather than this machine. Results are listed apart, under the name
  of the individual who builds them, and only from projects that build
  for this Fedora and architecture. Installing one adds its repository
  as part of the same transaction, so it asks for a password once
  instead of twice, and the "Installed" chip goes to the project the
  package actually came from — five Coprs can build the same name.
- **"Chroot not found in the given Copr project" now says what it
  means.** Adding a Copr that has no build for your Fedora answered with
  dnf's download progress, that sentence, and a screenful of EPEL chroot
  names, cut off mid-list. It says "This Copr has no builds for Fedora
  44 (x86_64)" instead, and the progress lines no longer arrive as the
  first line of an error.
- **Atomic Fedora is supported, experimentally.** Silverblue, Kinoite,
  Bazzite and Bluefin were being handed to libdnf5, which cannot write
  `/usr`. They are their own backend now, driven through `rpm-ostree`:
  installing layers a package, removing unlayers one, and an update is
  the whole deployment rather than a choice of packages. Nothing takes
  effect until the next boot, so a finished transaction says "takes
  effect after reboot" and raises the reboot notice instead of claiming
  the package is in use. Removing something that came with the image is
  refused with the reason. Software sources work there too — the
  repository list, the switches and adding a Copr no longer need dnf to
  be installed, which also fixes the sources list on a Fedora without
  `python3-libdnf5`.

## 0.7.0 — 2026-08-10

- **The update notice now covers every version you skipped.** It showed
  the newest release's notes and stopped there, so two versions behind
  meant one version's notes — the other's fixes stayed invisible. It now
  gathers every section newer than the installed version and says how
  many releases that is.
- **Those notes are read as text, not printed as a file.** CHANGELOG.md
  is hard wrapped for a terminal, so the banner drew short lines while
  having twice the width to give, and `**bold**` stood as four asterisks.
  Continuations are rejoined, bold, code and links become what they mean,
  and each version heading carries its number in the accent colour. The
  notes sit in a bounded, scrollable box — several releases do not fit a
  banner, and cutting them off hides the very fixes that were skipped.
  The About popup shows them as well.
- **A new plugin version announces itself**, once per version, the same
  way new packages do — the banner was only seen by someone who happened
  to open the window. Respects the "Automatic updates: off" setting.
- **The dashboard's headings lead where they summarise**: "Installed
  software" and "Recently updated" are links to their tabs, with a hover
  underline and a chevron.
- **The three support links now also sit in About**, stacked and left
  aligned there, three across on the dashboard.

## 0.6.9 — 2026-08-10

- **A package name in the log leads to the package.** Hover a name in an
  expanded log entry and it underlines; click it and the same details
  popup the tabs use opens, changelog included. The log is where you
  notice a version you did not expect, and reading up on it no longer
  means finding the package again by hand. Entries now record what a
  package is called as well as what it is displayed as; older entries
  still work where the name is a package name.
- **A "Network and privacy" section in the README**, listing every
  outgoing connection the plugin makes and when. There is no tracking of
  any kind and no server belonging to this project, but there is more
  traffic than "updates and a version check": ratings and reviews from
  ODRS, Flathub's app data, screenshots from AppStream URLs, the AppImage
  catalogue. Two details are stated plainly — reading reviews sends a
  constant hash that identifies nobody, and submitting one is the single
  request carrying anything machine-specific.
- **The review form says what happens if you leave the name empty**:
  your login name is published. It used to be a silent fallback.
- **A translation checker** (`scripts/check_translations.py`): identical
  key sets across the fifteen catalogs, every string the UI asks for,
  placeholders kept in each translation, and keys nothing calls any more.
  It found the details popup printing a raw source id — "fedora: 12 MB
  download" next to translated text in every language — and ten dead keys.
- A long version no longer wraps onto a second line in the log while the
  row still has room to its right.

## 0.6.8 — 2026-08-10

- **"python3-libdnf5 is missing" was sometimes simply wrong** (#3). On a
  Fedora 44 machine where the package was installed, every system update
  failed on a binding the app said was absent. The helpers are started as
  `python3 <script>`, which is whatever PATH means in the shell's process
  — a pyenv shim, a uv or conda environment, an activated virtualenv —
  and the bindings are installed into the system interpreter and nowhere
  else. A helper that cannot import its binding now hands the command to
  a system interpreter that can, outside that environment. All five
  bindings are covered: libdnf5, python-apt, pyalpm, PyGObject and
  PyYAML.
- **A Flatpak run could die before its first word.** PyGObject's import
  in the flatpak helper was not guarded at all, so on a wrong interpreter
  the process ended before any event: the run reported that everything
  failed and could say nothing about why. On every distribution, not only
  on Fedora.
- **A failure that is counted is now a failure that is shown** (#2). A
  Flatpak transaction touches refs the pending list never mentioned —
  extensions, themes, drivers, runtimes pulled along. When one of those
  failed, the counter went up and the reason was dropped for want of a
  row, so a run could end in "1 failed" with every line it showed in
  green and nothing to read anywhere. Such a failure now gets a row, with
  the ref's name and the transaction's own words. The same hole is closed
  where a whole installation's transaction fails, where the helper exits
  non-zero, and where a system dependency the resolver pulled in fails.
- When a binding still cannot be loaded, the card names the interpreter
  that could not load it and no longer asserts that the package is
  missing — a diagnosis that cannot be contradicted is worse than none.

## 0.6.7 — 2026-08-09

- Tab hover is one sliding highlight that follows the pointer and fades
  where it is — visited tabs no longer keep a leftover glow
- When an update run starts, the list jumps to the top where the
  in-progress group is, also for a user who had scrolled down

## 0.6.6 — 2026-08-09

- Updates from Copr repositories no longer fail with a silent
  "nothing to do": the update check refreshes repository metadata, but
  the transaction resolved against the cached view — up to 48 hours old
  for Coprs — so a freshly offered build could be invisible to the very
  run that was supposed to install it. The rpm helper now refreshes
  metadata before every transaction, the same way the check does.
- A run that genuinely resolves to nothing is reported as such per
  package, instead of as "the package helper could not start".

## 0.6.5 — 2026-08-08

- **Software sources, as a panel rather than as a wiki page.** The Install
  tab's header button (or Ctrl+K → Software sources) shows what this
  machine is configured with and offers the changes that are safe to
  express as a button:
  - **RPM Fusion when it is missing**, both flavours in one step — most
    of nonfree builds on free, so adding nonfree alone is half an
    installation.
  - **The well-known Flatpak remotes as buttons** instead of as
    addresses to look up: Flathub, Flathub Beta, Fedora Flatpaks, GNOME
    and KDE nightly. What you already have says so instead of offering
    itself again. Anything else goes in by `.flatpakrepo` address.
  - **The configured repositories with switches**, and Copr add and
    remove. Debug, source and testing repositories are folded away —
    they are two thirds of the list on a normal Fedora.
  Switching off a repository the distribution is made of asks twice, as
  does any removal. Writing a repository definition by hand stays a text
  editor's job. Changes to `/etc` go through pkexec; Flatpak remotes are
  added for you alone and ask for nothing. Every change that succeeds is
  logged; every one that fails keeps the tool's own words. Only the dnf
  family can be changed from here: apt and pacman sources are listed
  read-only, because an apt source is a file plus a signing key and a
  pacman repo lives in a single hand-edited `pacman.conf`.
- The command palette hands its query to **Installed and Log** as well as
  to Install, so the first few matches are no longer the only way onward.
  Its direct log results are gone: activating one opened the newest entry
  rather than the one that was clicked.
- **The palette opens empty and takes the keyboard.** It came back with
  the previous query still in it, the old row still selected, and the
  first keystrokes still going to the window behind it — one dead
  reference behind all three, silent because QML errors raised in a
  plugin file never reach the journal.
- **Opening the app when it is already open brings it to you** instead of
  appearing to do nothing behind another window (niri and Hyprland are
  asked directly; elsewhere the window re-maps). The same fix revealed
  that the three-minute timer returning an idle window to the Updates tab
  had never run, for the same reason.
- **The app can put itself in your launcher**, and does it from the
  Updates tab with a close button that is remembered, or from Settings at
  any time. Both write the entry *and* its icon — the documented manual
  step never mentioned the icon, which is a launcher item with a blank
  tile.
- Fix: the duration forecast built "usually about 5 min here" by deleting
  the word "left" from a translated phrase, which only works in languages
  that put that word last.

## 0.6.0 — 2026-08-08

- **A command palette on Ctrl+K.** One field over everything the window
  already holds — pending updates, installed software and the app's own
  commands — filtered as you type, with no process to wait for. Arrows
  move, Enter acts, Escape leaves. It deliberately does not search the
  repositories: that needs a process and a cache the Install tab already
  owns, so the last results hand the query to Installed, Install or Log
  instead of growing a second search engine here. Reachable from a
  magnifier in the header, which carries the shortcut in its tooltip.
- **Show what Update All would do, before the click.** A strip above the
  list states the resolver's own answer: how many packages the
  transaction really touches, how much arrives, what it costs or frees on
  disk, how many were pulled in as dependencies nobody selected, and — in
  warning colour — anything that would be removed. It comes from the same
  `plan` event the run consumes, fetched without root, so the preview
  cannot drift from the transaction it describes.
- **Say what a removal takes with it, before it takes it.** Removing one
  package can remove others, and that used to happen in silence: only
  packages you picked ever got a row, so anything the resolver decided to
  remove left no trace. The details popup now names them. `plan` became a
  prefix on any action rather than an action of its own, which is what
  makes an unprivileged preview possible at all.
- **Not every update is equally urgent, and the list now says so.**
  Fedora ships updateinfo next to its packages — which update closes a
  security hole, which fixes a bug, and the CVE behind it. Read from the
  local cache, so it costs no root and no network. Only the dnf family
  publishes this in a locally readable form; elsewhere it shows as no
  chip rather than as a reassuring absence of danger.
- **Why is this on my system, answered.** Did you ask for this package or
  did it arrive as somebody's dependency, and what would miss it if it
  went — one line in the details popup, from facts every package manager
  keeps behind flags nobody remembers.
- **Reclaim space: the two piles nobody looks at** — packages pulled in
  for something since removed, and the download cache of files already
  installed, each with its measured size and its own button. The card
  stays hidden below 50 MB, where the offer would be noise.
- **How long this usually takes here, measured rather than guessed.**
  Every run reports its own duration and size and the last ten are kept;
  the forecast is the median seconds per package, so one run that hit a
  slow mirror does not set the expectation. It stays silent until this
  machine has shown at least two runs.
- **The log becomes a timeline** — a heading per day, a dot per event on
  a rail that runs between them, and above it what the log always knew
  and never said: how many packages were updated, installed and removed
  in the last seven days.
- **The app can put itself in your launcher.** Enabling a plugin cannot
  write a desktop entry, so until now the window was reachable from the
  bar and nowhere else unless you found the README step and repeated it
  on every machine. The Updates tab offers it once, with a close button
  that is remembered, and Settings keeps the switch permanently — on
  places the entry and its icon in your own home directory, off takes
  them away. No password, nothing outside your home.
- **Opening the app when it is already open now brings it to you**
  instead of appearing to do nothing behind another window. A Wayland
  window cannot raise itself, so the compositor is asked (niri, Hyprland,
  and a re-map elsewhere).
- **AppImages install into `~/AppImages`** whether or not Gearlever is
  there, created on first install. The old chain used it only if it
  already existed and otherwise fell back to `~/Applications`, which
  quietly split installs across two folders. Gearlever's own setting
  still wins where it points elsewhere, and existing `~/Applications`
  installs keep being listed and updated in place.
- Fixes: the cache row measured repository metadata rather than package
  files, and offered to free something `clean packages` never touches —
  and then wrote "Emptied the package cache" for runs that emptied
  nothing, because the command exits 0 with nothing to clean. Cleanups
  are now logged by what they actually freed. The three-minute timer that
  returns an idle window to the Updates tab read a window property that
  does not exist, so it had never run. Colours written into a JS model
  are strings, and blending one silently produced an invalid colour —
  which draws as nothing.
- Three quiet support chips under the dashboard cards: the plugin
  registry entry, the repository, and Vito — the last drawn as its own
  five bars, which take the brand gradient on hover.

## 0.5.1 — 2026-08-08

- **Six more languages: Ukrainian, Russian, Hungarian, Japanese, Korean
  and Vietnamese** — sixteen in total. Chosen by measuring the shared
  DankMaterialShell catalogs rather than guessing: these all sit between
  88% and 97% translated, above several languages this plugin already
  shipped. Arabic and Hebrew score highest of all but are still missing,
  because the layout has no right-to-left handling and shipping the text
  without it would be half a job.
- **No Firmware tab when firmware updates are switched off** in the
  plugin settings — a tab for something you turned off is a dead end.
- The main tabs have a visible hover state, and the spinning refresh
  icons no longer look ragged while they turn: they were drawn with
  pixel-grid hinting, which does not survive rotation.
- On the dashboard the footer no longer reserves room for an Update All
  button that is not there, so the cards get the space instead of
  scrolling early.
- Two quiet links under the dashboard cards, to the plugin registry entry
  and the repository.

## 0.5.0 — 2026-08-08

- **A missing package-manager binding no longer looks like hundreds of
  failed packages.** `python3-libdnf5` is not part of a default Fedora
  install, and without it the rpm helper died on its import before its
  first event — so an update run marked every system package as failed
  within seconds, for no stated reason. The helpers now report a missing
  binding through the event protocol, the plugin asks them at startup
  (`selftest`) and shows a card naming the package, with a button that
  installs it and the command for anyone who would rather do it in a
  terminal. A run that cannot start says so once instead of blaming each
  package.
- The same card reports a **missing AppStream catalog**
  (`appstream-data`, `appstream`, `archlinux-appstream-data`), which is
  what gives system packages their real names, icons and release notes
  and is just as easy to be without. That one is a note rather than an
  error: the plugin falls back to package summaries and desktop-entry
  icons, so apps still look like apps.
- **The final DankMaterialShell pass stays inside its own scope.** That
  pass runs through the update daemon, whose upgrade command means
  "everything pending" — so after a failed system pass it quietly
  installed those packages too: minutes without visible progress, and
  packages that ended up installed while the log recorded them as
  failed. The pass now carries an ignore list of everything it is not
  responsible for.
- Failed rows carry the tool's own words. The card shows the short
  reason and offers **Show details** for the verbatim output; the action
  log keeps both, so a failure can still be reported after the fact.
- **A failure outlives the run panel.** A package that failed is still a
  pending update, so it comes back in the list — and now it brings its
  reason with it, restored after the shell reload that a DankMaterialShell
  pass causes. The verdict is dropped as soon as the package stops being
  pending, so a stale failure can never haunt a package that has since
  been updated. The result panel also links straight to its own entry in
  the log, and its "%1 updated · %2 failed" summary now actually appears
  after a failed run — it was written for a phase that run never reaches.
- The action log is reconciled with the system: a package that failed
  before the shell pass but did arrive is recorded as updated, and a run
  torn down by a shell reload no longer leaves a stray "0 packages
  updated" entry.
- Update cards pack their chips, buttons and status icons into one
  cluster against the right edge, aligned with each other.
- **During a run the list groups by what is happening**, not by what kind
  of package it is: what is being downloaded or installed right now sits
  at the top, then what is still waiting, then what this round already
  finished — collapsed, because a long run finishes far more packages
  than it works on at once. Failures sort to the top of the finished
  group. Every section header carries an icon and a count, so "how many
  are still waiting" is answerable at a glance.
- A fresh install starts at **Notify only** instead of Off — finding
  updates and saying nothing helps nobody. An explicit Off is kept.
- **Installed** shows the programs you use above the packages that hold
  them up, in two named groups. A package counts as an application when
  it owns a desktop entry the launcher would show — which also gives an
  icon and a name to packages AppStream never heard of (COPR builds,
  third-party repos), so Nautilus and Remmina look like themselves again.
- **The last two Debian/Arch metadata gaps are closed.** Package
  changelogs come from `/usr/share/doc` on apt and `pacman -Qc` on Arch,
  read locally rather than over the network, and the AppStream catalog is
  read from DEP-11 YAML on the Debian family (apt's own lists and the
  appstream cache) and from the legacy XML path Arch's
  `archlinux-appstream-data` still uses. DEP-11 release notes go through
  the same markup reduction as every other external source.

## 0.4.0 — 2026-08-07

- **Experimental Debian/Ubuntu and Arch support.** The plugin now detects
  the distro family and switches its whole package layer: transactions
  run through python-apt or pyalpm (same live byte-progress as on
  Fedora), and search, package info, update sizes, installed inventory,
  holds and the dashboard all have apt and pacman implementations.
  **Experimental means experimental**: everything is container-tested
  (real installs, removals and upgrades on Debian trixie and Arch) but
  not yet validated on real desktop installs — these systems show a
  banner with a "Report an issue" button, and PROTOCOL.md tracks the
  known gaps (package changelogs, AppStream catalog paths, update-check
  daemon behaviour). Fedora code paths are untouched.
- Arch specifics: official repositories only — AUR transactions are
  deliberately out of scope (the interactive PKGBUILD review exists for
  safety); AUR/foreign packages do appear read-only as their own count
  on the dashboard. Version restore is unavailable (pacman repositories
  keep no history).
- The reboot recommendation, install labels, search placeholders and
  post-run verification all follow the detected backend.

## 0.3.0 — 2026-08-07

- **Programmatic dnf.** All rpm transactions (installs, removals,
  downgrades and the system pass of update runs) now go through a new
  libdnf5 helper — the library dnf5 itself uses — instead of scraping
  command output. Progress comes from real library callbacks: exact
  per-package download bytes, a steady aggregate transfer counter, and
  per-package rpm install progress. Failures carry the library's actual
  error message. The DMS daemon remains for update checks and the
  DankMaterialShell self-update pass (which must survive the shell
  reload).
- The helper event protocol is documented in PROTOCOL.md and is
  package-manager-agnostic by design — groundwork for possible
  apt (Debian) and pacman (Arch) backends later.
- Update runs that update DMS itself no longer lose their action-log
  entry to the shell reload: the entry is stashed beforehand and written
  at the next start, verified against the rpm database, with its
  original timestamp.
- Clicking the updates notification (or its Open button) opens the main
  window on the Updates tab.
- Update-run reliability: waits on a busy daemon are now time-capped and
  a lost backend selection triggers a re-check — a stuck "preparing"
  phase can no longer hang for minutes.
- Dashboard rearranged: system/status on top, installed/recently-updated
  below, equal heights, top-aligned content, larger card titles; the
  recently-updated card scrolls through the last 50 packages.
- Flatpak runtimes and extensions are hidden by default (still always
  updated; a footnote points to the setting).
- Confirm buttons on red fills pick black or white by the fill's
  lightness — readable in every theme.

## 0.2.3 — 2026-08-06

- **Delayed updates removed.** The maturity window kept fighting the
  package manager: updates had to release as complete source families,
  dependencies crossed family lines (gjs needing the still-delayed
  mozjs140), and every exception needed another workaround. Fedora's own
  update pipeline (Bodhi) already gates stable updates upstream, so the
  extra client-side window added little real protection while delaying
  bug and security fixes. Held packages and per-app version restore
  remain the honest tools for staying in control; stored delay settings
  and clocks are cleaned up automatically.
- Update runs verify against the rpm database when a pass ends: a pass
  that silently installed nothing can no longer report success — rows
  that never reached their target version fail visibly with a reason
- The run engine no longer interrupts a working dnf process: the retry
  nudge waits well past resolve time, backs off while daemon output
  streams, and never fires an upgrade into a running check (these
  collisions were killing transactions mid-resolve)
- Failed check errors render as a bounded, wrapped message instead of
  stretching the header off-screen
- Update notifications carry the plugin's own icon, following the
  light/dark theme
- Waiting texts animate: a brightness wave slides across the trailing
  dots, without the text ever changing width
- The reboot banner now says a **computer** restart is recommended —
  "restart" was ambiguous next to shell reloads
- Held packages stay listed during an update run

## 0.2.2 — 2026-08-06

- Six new UI languages: Spanish, Portuguese, Italian, Polish, Swedish and
  Chinese (Simplified) — ten languages in total
- Real per-package download progress for system packages: bars build up
  with actual bytes ("downloading · 37% · 6.7 MB / 18 MB") read live from
  the dnf cache, instead of sitting still and jumping to 100%
- Finished downloads read "downloaded" through the silent
  transaction-prepare wait instead of a stuck "downloading · 100%"
- Progress lines map to the right row in subpackage families
- The delayed-updates countdown no longer restarts after suspend/resume —
  first-seen clocks survive the shell rebuilding its bar
- Update notifications carry the plugin's own icon, following the
  light/dark theme

## 0.2.1 — 2026-08-05

- Update runs are far more reliable: a run right after a service restart
  first triggers a check instead of silently doing nothing, and daemon
  passes retry patiently (the final DMS pass no longer fails while the
  service is still busy)
- Failed updates show why (service error message or a clear retry hint),
  with a failure color that stays readable in light mode
- The misleading overall progress bar is gone — the phase stepper and
  per-package progress rows tell the real story; the bar pill shows
  completed/planned during a run
- Delayed updates mature and release as complete source families, so dnf
  can never skip half a family
- After a restart the restored update list is reconciled against what is
  actually installed, and a fresh check starts automatically
- Update All flips to Cancel immediately; "Loading repositories…" shows
  during the silent metadata phase
- Review form: reviewer-name field (remembered), clearer summary/body
  layout, live star hover; reviews disabled for AppImages

## 0.2.0 — 2026-08-05

- The plugin now updates itself: a banner announces new releases with their
  release notes and updates with one click (dismissible per version; also
  shown in the About popup)
- About popup behind the new info icon: version, supported sources, license
  and GitHub link
- Delayed updates: the countdown survives shell and computer restarts,
  ticks down properly and reads "released for install in …"
- The update list restores instantly after a restart from a persisted
  snapshot instead of staying empty until the next check
- Details popup opens ~5× faster: the description shows after ~1 second,
  screenshots/sizes/reviews stream in as they arrive
- Reviews: reviewer-name field (remembered), summary and body visually
  distinct, live star hover preview; disabled for AppImages (they have no
  shared ODRS identity to review against)
- Window reopens correctly after a compositor-side close (Super+Q)
- Minimum DMS version lowered to 1.5

## 0.1.0 — 2026-08-05

Initial public release.

- Updates tab with rich cards, release notes, held & delayed updates and live progress with ETA
- App store across Fedora repos, Flathub and the AppImage catalog, with ODRS ratings and reviews
- Installed-software management: uninstall, hold, downgrade, AppImage GitHub update sources
- Firmware updates (fwupd) and a persistent action log
- UI in English, Dutch, German and French
