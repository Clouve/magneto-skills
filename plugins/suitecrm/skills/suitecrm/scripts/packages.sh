#!/usr/bin/env bash
# SuiteCRM skill: packages.sh
#
# Module Loader packages: the add-ons that come as a zip with a manifest.php and are installed in SuiteCRM under
# Admin > Module Loader. This script lists what is installed, vets a zip without running anything in it,
# installs it through SuiteCRM's own Module Loader code, and uninstalls it.
#
# Usage:
#   packages.sh list
#   packages.sh inspect <file.zip>
#   packages.sh install <file.zip> --sha256 <value> --yes-install
#   packages.sh uninstall <id> [--remove-tables] --yes-uninstall
#
#   list       the packages SuiteCRM knows: id, name, version, status and when each was installed.
#   inspect    unpacks the zip in a temp folder on the agent and reports, without running any of it: the
#              file's sha256 checksum; the manifest's name, version and the SuiteCRM versions it accepts;
#              the id; where it copies files to; whether it brings install or uninstall scripts
#              (pre_install, post_install, pre_uninstall, post_uninstall, pre_execute, post_execute); and
#              every line of its PHP that runs commands, evaluates code, calls out to the network, or drops,
#              deletes or truncates tables. A package with none of that still runs as the web user and can
#              do anything SuiteCRM can: read the code that the report points at before the user's yes.
#   install    sends the zip to SuiteCRM and installs it. It needs --sha256 with the checksum that inspect
#              printed, so that what is installed is the file that was inspected: a file whose checksum
#              differs is refused (exit 65, nothing installed), here and again in the SuiteCRM container
#              for the bytes that arrived. It needs --yes-install, and a backup made by this skill in the
#              last 24 hours (exit 76 without one). SuiteCRM refuses a package whose manifest does not
#              accept version 8.10.2 (exit 65).
#   uninstall  removes an installed package by its id: its files, and what it added to screens and menus. The
#              tables and custom fields the package made stay, with the data in them, unless --remove-tables is
#              given. With it they are dropped, and the data in them is gone for good (that is what SuiteCRM's
#              own uninstall screen does by default). It needs --yes-uninstall and a recent backup. SuiteCRM
#              undoes a package from the copy of its zip that it kept at the install. When that copy is
#              gone the uninstall is refused (exit 2, nothing changed): SuiteCRM would only take the package
#              off its list and leave every file of it in place.
#
# A package is arbitrary PHP from a third party. Take it only from its publisher's own site or the SuiteCRM
# store, and say so to the user. SuiteCRM 8 "extensions" (folders under extensions/) are a different thing:
# the ones with a browser part need a build step this image can't do (reference/packages-and-repair.md).
#
# Env vars read: SUITECRM_HOST (through run-in-suitecrm.sh, which also loads the ops password).
#
# Exit codes: 0 done; 64 usage, the yes or --sha256 is missing, or the file can't be read; 65 not a package,
# the file is not the one that was inspected (its checksum differs), or SuiteCRM does not accept it; 76 no
# backup from the last 24 hours; 1 unzip or sha256sum is missing; 2 the install or uninstall did not end as
# expected, or the uninstall was refused because SuiteCRM's stored copy of the zip is gone; 3 no such
# installed package; 4 it is installed already; 70, 75, 255 from run-in-suitecrm.sh.

set -uo pipefail

usage() {
    cat <<'USAGE'
Usage: packages.sh list
       packages.sh inspect <file.zip>
       packages.sh install <file.zip> --sha256 <value> --yes-install
       packages.sh uninstall <id> [--remove-tables] --yes-uninstall

Module Loader packages. list shows what is installed. inspect reads a zip without running it and reports
its sha256 checksum, what it copies where, its install scripts and its risky code. install takes that
checksum (--sha256) and refuses a file that is not the one that was inspected. install and uninstall go
through SuiteCRM's own Module Loader code, after the user's yes and a backup. uninstall keeps the tables and
custom fields a package made unless --remove-tables is given, which drops them and their data for good. It
is refused when SuiteCRM no longer has its stored copy of the package's zip.

Exit codes: 0 done; 64 usage, no yes or no --sha256; 65 not a package SuiteCRM accepts, or not the file
that was inspected; 76 no backup from the last 24 hours; 1 unzip or sha256sum is missing; 2 did not end as
expected, or the stored zip is gone; 3 not installed; 4 installed already; 70 the script crashed; 75
SuiteCRM is being installed or upgraded; 255 ssh failed.
USAGE
}

msg() { printf '[suitecrm/packages] %s\n' "$*" >&2; }
usage_error() {
    msg "$1"
    usage >&2
    exit 64
}

# The runner's php form says which script of the skill called it.
export SC_SKILL_CALLER=packages.sh

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
run="${script_dir}/run-in-suitecrm.sh"

# home_path PATH: PATH with a leading ~/ turned into the home folder. A path from the Files pane is often
# written ~/name, and inside quotes the shell leaves the ~ as it is.
home_path() {
    # shellcheck disable=SC2088  # the pattern is a literal ~/ on purpose
    case "$1" in "~/"*) printf '%s' "${HOME}/${1#"~/"}" ;; *) printf '%s' "$1" ;; esac
}

# need_zip FILE: a readable file of at most 100 MB
need_zip() {
    if [ ! -f "$1" ] || [ ! -r "$1" ]; then usage_error "can't read the file $(printf '%q' "$1")"; fi
    local size
    size="$(stat -c %s -- "$1" 2> /dev/null || echo 0)"
    [ "${size}" -gt 0 ] || usage_error "the file is empty"
    [ "${size}" -le 104857600 ] || usage_error "the file is larger than 100 MB"
}

# zip_sha256 FILE: the file's sha256 checksum, 64 hex digits
zip_sha256() {
    local sum
    command -v sha256sum > /dev/null 2>&1 || { msg "sha256sum is not installed"; exit 1; }
    sum="$(sha256sum -- "$1" 2> /dev/null)" || { msg "could not read $(printf '%q' "$1")"; exit 1; }
    sum="${sum%% *}"
    [[ ${sum} =~ ^[0123456789abcdef]{64}$ ]] || { msg "sha256sum gave no checksum"; exit 1; }
    printf '%s' "${sum}"
}

inspect() {
    local zip="$1" tmp total listing risky scripts sum
    command -v unzip > /dev/null 2>&1 || { msg "unzip is not installed (the suitecrm plugin's install.sh adds it)"; exit 1; }
    # The checksum of the file as it is read here. install takes it, so what gets installed is this file.
    sum="$(zip_sha256 "${zip}")" || exit 1
    if ! listing="$(unzip -Z1 -- "${zip}" 2> /dev/null)" || ! grep -qx 'manifest.php' <<< "${listing}"; then
        msg "this is not a Module Loader package: it is not a zip with a manifest.php at its top."
        exit 65
    fi
    total="$(unzip -l -- "${zip}" 2> /dev/null | tail -n 1 | awk '{print $1}')"
    if ! [[ ${total} =~ ^[0-9]+$ ]] || [ "${total}" -gt 524288000 ]; then
        msg "the package unpacks to more than 500 MB, or its size can't be read; it was not unpacked."
        exit 65
    fi
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/suitecrm-package.XXXXXX")" || exit 1
    # shellcheck disable=SC2064  # the folder's name is fixed now
    trap "rm -rf '${tmp}'" EXIT
    if ! unzip -q -o -d "${tmp}" -- "${zip}" > /dev/null 2>&1; then
        msg "the zip could not be unpacked."
        exit 65
    fi
    if [ "$(zip_sha256 "${zip}")" != "${sum}" ]; then
        msg "the file changed while it was being read; run inspect again."
        exit 65
    fi
    printf 'Package file: %s (%s files, %s bytes unpacked)\n' "$(basename -- "${zip}")" "$(wc -l <<< "${listing}")" "${total}"
    printf 'sha256: %s\n\n' "${sum}"
    printf 'From manifest.php (text only; nothing in the package was run):\n'
    grep -nE "['\"](name|description|version|author|type|is_uninstallable|published_date|id)['\"][[:space:]]*=>|acceptable_(sugar|suitecrm)_versions|regex_matches|exact_matches" "${tmp}/manifest.php" | cut -c1-200 | sed 's/^/  /'
    printf '\nWhere it copies files to:\n'
    grep -noE "['\"](to|to_module)['\"][[:space:]]*=>[[:space:]]*['\"][^'\"]*['\"]" "${tmp}/manifest.php" | cut -c1-200 | sed 's/^/  /' || true
    printf '\nInstall and uninstall scripts:\n'
    scripts="$(grep -nE "['\"](pre_install|post_install|pre_uninstall|post_uninstall|pre_execute|post_execute)['\"]" "${tmp}/manifest.php" | cut -c1-200 || true)"
    scripts+="$(find "${tmp}" -path "${tmp}/scripts/*" -type f -printf '\nfile %P' 2> /dev/null || true)"
    if [ -n "${scripts//$'\n'/}" ]; then
        printf '%s\n' "${scripts}" | sed '/^$/d; s/^/  /'
        printf '  These run as the web user during the install or uninstall. Read them.\n'
    else
        printf '  No install scripts: the manifest names none and the zip has no scripts/ folder.\n'
    fi
    printf '\nCode to read before a yes (commands, evaluated code, network calls, table drops and deletes):\n'
    risky="$(cd "${tmp}" && grep -rnE --include='*.php' --include='*.inc' --include='*.tpl' \
        '\b(eval|assert|shell_exec|exec|system|passthru|popen|proc_open|pcntl_exec|create_function|base64_decode|gzinflate|str_rot13|curl_exec|fsockopen|stream_socket_client|mail)[[:space:]]*\(|`[^`]*`|\b(DROP|TRUNCATE)[[:space:]]+TABLE|\bDELETE[[:space:]]+FROM|file_(get|put)_contents[[:space:]]*\([[:space:]]*.https?:|\$_(GET|POST|REQUEST|COOKIE)\b.*\b(include|require)' . 2> /dev/null | cut -c1-220 | head -n 60 || true)"
    if [ -n "${risky}" ]; then
        printf '%s\n' "${risky}" | sed 's/^/  /'
    else
        printf '  None of those patterns were found. That is not proof the package is safe.\n'
    fi
    printf '\nNothing was installed. Show this to the user, and say where the package came from.\n'
    printf 'To install this very file after a clear yes: packages.sh install <file.zip> --sha256 %s --yes-install\n' "${sum}"
}

case "${1:-}" in
    -h | --help) usage; exit 0 ;;
    list)
        [ "$#" -eq 1 ] || usage_error "list takes no arguments"
        exec "${run}" php packages.php list
        ;;
    inspect)
        [ "$#" -eq 2 ] || usage_error "inspect takes one zip file"
        zip="$(home_path "$2")"
        need_zip "${zip}"
        inspect "${zip}"
        ;;
    install)
        [ "$#" -ge 2 ] || usage_error "install takes one zip file"
        zip="$(home_path "$2")"
        need_zip "${zip}"
        name="$(basename -- "${zip}")"
        [[ ${name} =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,120}\.zip$ ]] || usage_error "rename the file first: its name may hold only letters, digits, dots, dashes and underscores, and must end in .zip"
        shift 2
        want_sum=''
        yes=0
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --sha256)
                    [ "$#" -ge 2 ] || usage_error "--sha256 needs the checksum that packages.sh inspect printed"
                    want_sum="${2,,}"
                    [[ ${want_sum} =~ ^[0123456789abcdef]{64}$ ]] || usage_error "--sha256 takes 64 hex digits: the checksum that packages.sh inspect printed"
                    shift 2
                    ;;
                --yes-install) yes=1; shift ;;
                *) usage_error "unknown option for install: $(printf '%q' "$1")" ;;
            esac
        done
        if [ -z "${want_sum}" ]; then
            msg "nothing was installed. install needs --sha256 with the checksum that packages.sh inspect printed for this file, so that what is installed is the file that was inspected. Inspect it first, and show the user the report and where the package came from."
            exit 64
        fi
        if [ "${yes}" -ne 1 ]; then
            msg "nothing was installed. A package runs its own code as the web user. Inspect it first (packages.sh inspect), show the user the report and where the package came from, and run this again with --yes-install after a clear yes."
            exit 64
        fi
        have_sum="$(zip_sha256 "${zip}")" || exit 1
        if [ "${have_sum}" != "${want_sum}" ]; then
            msg "nothing was installed. This is not the file that was inspected: its sha256 is ${have_sum}, and --sha256 says ${want_sum}. The file changed, or it is another file. Run packages.sh inspect on it again and show the user the new report."
            exit 65
        fi
        # The checksum goes along: the container checks the bytes that arrive against it before anything is written.
        "${run}" --stdin --need-backup php packages.php install "${name}" "${want_sum}" < "${zip}"
        exit $?
        ;;
    uninstall)
        [ "$#" -ge 2 ] && [[ $2 =~ ^[A-Za-z0-9_.-]{1,120}$ ]] || usage_error "uninstall takes a package id (packages.sh list shows them)"
        id="$2"
        shift 2
        tables=keep
        yes=0
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --remove-tables) tables=remove; shift ;;
                --yes-uninstall) yes=1; shift ;;
                *) usage_error "unknown option for uninstall: $(printf '%q' "$1")" ;;
            esac
        done
        if [ "${yes}" -ne 1 ]; then
            if [ "${tables}" = remove ]; then
                msg "nothing was removed. This uninstalls the package ${id} from SuiteCRM and drops the tables and custom fields it made: the data in them is gone for good. Show that to the user, and run this again with --yes-uninstall after a clear yes."
            else
                msg "nothing was removed. This uninstalls the package ${id} from SuiteCRM; what it added to screens and menus goes with it, and the tables and custom fields it made stay. Show that to the user, and run this again with --yes-uninstall after a clear yes."
            fi
            exit 64
        fi
        exec "${run}" --need-backup php packages.php uninstall "${id}" "${tables}"
        ;;
    '') usage_error "no action given" ;;
    *) usage_error "unknown action: $(printf '%q' "$1")" ;;
esac
