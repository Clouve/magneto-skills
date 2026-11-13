# shellcheck shell=bash
# LimeSurvey skill: lib/limesurvey-files.sh (sourced by the scripts, not run)
#
# Private files in the agent user's home, which the Files pane shows: temporary passwords, exported answers and
# survey archives. Sourcing this file only defines functions. It creates nothing, reads nothing and leaves the
# shell's options, umask and traps as they were.
#
# ls_generate_password
#   Prints a new password and a newline: 20 characters from
#   ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789, which leaves out I, O, l, 0 and 1 so it can be read
#   aloud or retyped. The characters come from /dev/urandom through `tr -dc`, so each one is equally likely. A draw
#   without an upper-case letter, a lower-case letter and a digit is thrown away and drawn again. Returns 1 if it
#   cannot draw one.
#
# ls_private_dir <folder>
#   Makes ~/<folder> with mode 700 (an existing one is set to 700 too) and prints its path. <folder> is
#   limesurvey-passwords, limesurvey-exports or limesurvey-backups. Returns 1 if HOME is not an existing folder, or
#   the folder cannot be made.
#
# ls_free_name <dir> <base> <ext>
#   Prints <base>.<ext>, or <base>-2.<ext>, -3 and so on: the first name nothing in <dir> has, so one file never
#   replaces another. Returns 1 after 999 tries.
#
# ls_write_private_file <folder> <name>
#   Writes stdin to ~/<folder>/<name> with mode 600, made under umask 077 and checked with chmod, so the content is
#   never in a file others can read. It refuses to overwrite: anything already at the path stops it, whether a
#   file, a folder, a FIFO or a link of any kind. When it is done it checks that the path still holds the plain
#   file it made. <name> is a plain file name, with no slash. Returns 1, with a message on stderr, if it cannot
#   write the file. A file it made and could not finish is removed again.
#
# ls_delete_private_file <path>
#   Removes a file with shred -u when that works, else rm -f. Fails if the file is still there.
#
# None of them prints a password anywhere but stdout (ls_generate_password), and the messages show
# ~/<folder>/<name>, never the full path.

ls_generate_password() {
    local alphabet='ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    local pw=""
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        # head stops after 20 characters, and tr then dies of SIGPIPE. Under pipefail that is a failing status for
        # a good draw, so the status is ignored and the length is what is checked.
        pw="$(LC_ALL=C tr -dc "${alphabet}" < /dev/urandom | head -c 20)" || true
        [ "${#pw}" -eq 20 ] || continue
        case "${pw}" in *[[:upper:]]*) ;; *) continue ;; esac
        case "${pw}" in *[[:lower:]]*) ;; *) continue ;; esac
        case "${pw}" in *[[:digit:]]*) ;; *) continue ;; esac
        printf '%s\n' "${pw}"
        return 0
    done
    echo "[limesurvey/files] could not draw a password from /dev/urandom" >&2
    return 1
}

ls_private_dir() {
    local folder="${1:-}" dir
    case "${folder}" in
        limesurvey-passwords | limesurvey-exports | limesurvey-backups) ;;
        *)
            echo "[limesurvey/files] '${folder}' is not one of this skill's folders" >&2
            return 1
            ;;
    esac
    if [ -z "${HOME:-}" ] || [ ! -d "${HOME}" ]; then
        echo "[limesurvey/files] HOME is not an existing folder, so ~/${folder} has no place to go" >&2
        return 1
    fi
    dir="${HOME}/${folder}"
    if [ -e "${dir}" ] && [ ! -d "${dir}" ]; then
        echo "[limesurvey/files] ~/${folder} exists and is not a folder" >&2
        return 1
    fi
    if ! (umask 077 && mkdir -p -- "${dir}") || ! chmod 700 -- "${dir}"; then
        echo "[limesurvey/files] could not make ~/${folder} with mode 700" >&2
        return 1
    fi
    printf '%s\n' "${dir}"
}

ls_free_name() {
    local dir="$1" base="$2" ext="$3" name n=1
    name="${base}.${ext}"
    while [ -e "${dir}/${name}" ] || [ -L "${dir}/${name}" ]; do
        n=$((n + 1))
        if [ "${n}" -gt 999 ]; then
            echo "[limesurvey/files] ${dir##*/} already holds 999 files named ${base}*" >&2
            return 1
        fi
        name="${base}-${n}.${ext}"
    done
    printf '%s\n' "${name}"
}

ls_write_private_file() {
    local folder="${1:-}" name="${2:-}" dir path
    case "${name}" in
        '' | . | .. | */*)
            echo "[limesurvey/files] '${name}' is not a plain file name" >&2
            return 1
            ;;
    esac
    dir="$(ls_private_dir "${folder}")" || return 1
    path="${dir}/${name}"
    # Nothing may be at the path yet. noclobber alone is not enough: when the target exists and is not a regular
    # file (a link to /dev/null, a FIFO), bash skips O_EXCL and opens it, and opening a FIFO blocks until someone
    # reads it.
    if [ -e "${path}" ] || [ -L "${path}" ]; then
        echo "[limesurvey/files] will not write ~/${folder}/${name}: something is already there" >&2
        return 1
    fi
    # noclobber makes the redirection fail instead of truncating, and O_EXCL under it stops a link that appeared
    # since the check, even one that points nowhere, from being written through.
    if ! (set -o noclobber; umask 077; : > "${path}") 2> /dev/null; then
        echo "[limesurvey/files] will not write ~/${folder}/${name}: it exists, or cannot be made" >&2
        return 1
    fi
    # The file is ours from here on. chmod covers a default ACL on the folder, which umask does not.
    if ! chmod 600 -- "${path}" || ! cat >> "${path}"; then
        rm -f -- "${path}"
        echo "[limesurvey/files] could not write ~/${folder}/${name}" >&2
        return 1
    fi
    # Whatever is there now must still be the plain file this call made.
    if [ ! -f "${path}" ] || [ -L "${path}" ]; then
        echo "[limesurvey/files] ~/${folder}/${name} is not a plain file after the write" >&2
        return 1
    fi
}

ls_delete_private_file() {
    if command -v shred > /dev/null 2>&1 && shred -u -- "$1" 2> /dev/null; then
        return 0
    fi
    rm -f -- "$1"
    [ ! -e "$1" ] && [ ! -L "$1" ]
}
