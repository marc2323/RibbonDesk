#!/bin/zsh
# Also shipped as Install.command next to the prebuilt app and configuration.
set -euo pipefail
umask 077
ribbon_package="${0:A:h}"
ribbon_source="${1:-$ribbon_package/RibbonDesk.app}"
ribbon_lua="${2:-$ribbon_package/paneru-init.lua}"
# Isolated install checks use a dedicated root without changing HOME or services.
ribbon_root="${RIBBONDESK_INSTALL_ROOT:-$HOME}"
[[ "$ribbon_root" == /* && "$ribbon_root" != / ]] || { print -u2 'Invalid installation root.'; exit 1; }
ribbon_destination="$ribbon_root/Applications/RibbonDesk.app"
ribbon_legacy="$ribbon_root/Applications/Paneru Settings.app"
ribbon_old_launcher="$ribbon_root/Applications/Paneru.app"
ribbon_migrate_launcher=0
ribbon_config="$ribbon_root/.config/paneru"
ribbon_identifier='local.paneru.preferences'

ribbon_owned() {
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist")" == "$ribbon_identifier" ]]
}
ribbon_owned "$ribbon_source" || { print -u2 'The source is not a RibbonDesk app bundle.'; exit 1; }
/usr/bin/codesign --verify --deep --strict "$ribbon_source"
ribbon_binary_type=$(/usr/bin/file -b "$ribbon_source/Contents/MacOS/RibbonDesk")
[[ "$ribbon_binary_type" == *"$(/usr/bin/uname -m)"* ]] || { print -u2 'This download does not support this Mac’s architecture.'; exit 1; }
ribbon_os=$(/usr/bin/sw_vers -productVersion)
[[ "${ribbon_os%%.*}" -ge 13 ]] || { print -u2 'RibbonDesk requires macOS 13 or later.'; exit 1; }
[[ -f "$ribbon_lua" ]] || { print -u2 'Keep the app, installer, and configuration together.'; exit 1; }
for ribbon_app in "$ribbon_destination" "$ribbon_legacy"; do
    if [[ -e "$ribbon_app" ]]; then
        ribbon_owned "$ribbon_app" || { print -u2 -- "Refusing to replace an unrelated app: $ribbon_app"; exit 1; }
    fi
done
if [[ -f "$ribbon_old_launcher/Contents/Info.plist" ]] && \
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$ribbon_old_launcher/Contents/Info.plist")" == com.github.karinushka.paneru.launcher ]]; then
    ribbon_migrate_launcher=1
fi

if [[ "$ribbon_root" == "$HOME" ]]; then
    ribbon_running=$(/bin/ps -axo args= | /usr/bin/awk \
        -v current="$ribbon_destination/Contents/MacOS/RibbonDesk" \
        -v legacy="$ribbon_legacy/Contents/MacOS/PaneruSettings" \
        '$0 == current || $0 == current " --background" || $0 == legacy || $0 == legacy " --background" { print "running" }')
    ribbon_service=$(/bin/launchctl print "gui/$(/usr/bin/id -u)/com.github.karinushka.paneru" 2>/dev/null || true)
    if [[ -n "$ribbon_running" || "$ribbon_service" == *'state = running'* ]]; then
        print -u2 'Choose Quit in RibbonDesk (or the older Paneru Settings app), then run the installer again.'
        exit 1
    fi
fi

/bin/mkdir -p "$ribbon_root/Applications" "$ribbon_config/backups"
ribbon_stage=$(/usr/bin/mktemp -d "$ribbon_root/Applications/.ribbondesk-install.XXXXXX")
ribbon_backup=''
ribbon_committed=0
ribbon_installed=0
ribbon_config_installed=0
ribbon_rollback() {
    if (( ! ribbon_committed )); then
        (( ! ribbon_installed )) || /bin/rm -rf -- "$ribbon_destination"
        if [[ -n "$ribbon_backup" ]]; then
            [[ ! -e "$ribbon_backup/RibbonDesk.app.backup" ]] || /bin/mv "$ribbon_backup/RibbonDesk.app.backup" "$ribbon_destination"
            [[ ! -e "$ribbon_backup/Paneru Settings.app.backup" ]] || /bin/mv "$ribbon_backup/Paneru Settings.app.backup" "$ribbon_legacy"
            [[ ! -e "$ribbon_backup/Paneru.app.backup" ]] || /bin/mv "$ribbon_backup/Paneru.app.backup" "$ribbon_old_launcher"
            if (( ribbon_config_installed )); then
                if [[ -e "$ribbon_backup/init.lua" ]]; then /bin/cp -p "$ribbon_backup/init.lua" "$ribbon_config/init.lua"
                else /bin/rm -f "$ribbon_config/init.lua"; fi
            fi
        fi
    fi
    /bin/rm -rf -- "$ribbon_stage"
}
trap ribbon_rollback EXIT
/usr/bin/ditto "$ribbon_source" "$ribbon_stage/RibbonDesk.app"
/usr/bin/codesign --verify --deep --strict "$ribbon_stage/RibbonDesk.app"
/bin/cp "$ribbon_lua" "$ribbon_stage/init.lua"
ribbon_backup=$(/usr/bin/mktemp -d "$ribbon_config/backups/ribbondesk-install.XXXXXX")
for ribbon_file in init.lua preferences.json preferences.lua scroll-presets.json; do
    [[ ! -e "$ribbon_config/$ribbon_file" ]] || /bin/cp -p "$ribbon_config/$ribbon_file" "$ribbon_backup/$ribbon_file"
done
# A .backup suffix keeps Launch Services from discovering another launchable app.
[[ ! -e "$ribbon_destination" ]] || /bin/mv "$ribbon_destination" "$ribbon_backup/RibbonDesk.app.backup"
[[ ! -e "$ribbon_legacy" ]] || /bin/mv "$ribbon_legacy" "$ribbon_backup/Paneru Settings.app.backup"
(( ! ribbon_migrate_launcher )) || /bin/mv "$ribbon_old_launcher" "$ribbon_backup/Paneru.app.backup"
/bin/mv "$ribbon_stage/RibbonDesk.app" "$ribbon_destination"
ribbon_installed=1
/bin/mv "$ribbon_stage/init.lua" "$ribbon_config/init.lua"
ribbon_config_installed=1
/bin/chmod 600 "$ribbon_config/init.lua"
ribbon_committed=1
if [[ "$ribbon_root" == "$HOME" ]]; then
    ribbon_lsregister='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
    # Refresh the renamed bundle's display name and launch path in macOS.
    if [[ -x "$ribbon_lsregister" ]]; then "$ribbon_lsregister" -f "$ribbon_destination" || true; fi
fi
print -r -- "Installed: $ribbon_destination"
print -r -- "Previous app and configuration (if present): $ribbon_backup"
print -r -- 'Preferences and feel presets are preserved. Open RibbonDesk from your Applications folder to begin.'
