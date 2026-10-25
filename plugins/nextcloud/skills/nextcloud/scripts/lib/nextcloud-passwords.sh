# shellcheck shell=bash
# Nextcloud DevOps Skill: lib/nextcloud-passwords.sh (sourced by the scripts, not run)
#
# The password helpers temp-password.sh and share-as-admin.sh share. Sourcing this file
# only defines three functions. It creates nothing, reads nothing and leaves the shell's
# options, umask and traps as they were.
#
# nc_generate_password
#   Prints a new password and a newline: 20 characters from
#   ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789, which leaves out
#   I, O, l, 0 and 1 so it can be read aloud or retyped. The characters come from
#   /dev/urandom through `tr -dc`, so each one is equally likely. A draw without an
#   upper-case letter, a lower-case letter and a digit is thrown away and drawn again,
#   so the password also passes a policy that asks for each. Without that, about one
#   in twenty would have no digit. Returns 1 if it cannot draw one.
#
# nc_password_dir
#   Makes ~/nextcloud-passwords with mode 700 (an existing one is set to 700 too) and
#   prints its path. The Files pane shows that folder. Returns 1 if HOME is not an
#   existing folder, or the folder cannot be made.
#
# nc_write_private_file <name>
#   Writes stdin to ~/nextcloud-passwords/<name> with mode 600, made under umask 077
#   and checked with chmod, so the content is never in a file others can read. It
#   refuses to overwrite: anything already at the path stops it, whether a file, a
#   folder, a FIFO or a link of any kind (a link is not followed: one to /dev/null would
#   be opened through, and one to a FIFO would hang the open). When it is done it checks
#   that the path still holds the plain file it made. <name> is a plain file name, with
#   no slash. Returns 1, with a message on stderr, if it cannot write the file. A file it
#   made and could not finish is removed again.
#
# None of them prints a password anywhere but stdout (nc_generate_password), and the
# messages show ~/nextcloud-passwords/<name>, never the full path.
#
# Usage:
#   . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/nextcloud-passwords.sh"
#   pw="$(nc_generate_password)" || exit 1
#   printf '%s\n' "Password: ${pw}" | nc_write_private_file "alice-20261023-101500.txt" || exit 3

nc_generate_password() {
    local alphabet='ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    local pw=""
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        # head stops after 20 characters, and tr then dies of SIGPIPE. Under pipefail
        # that is a failing status for a good draw, so the status is ignored and the
        # length is what is checked.
        pw="$(LC_ALL=C tr -dc "${alphabet}" < /dev/urandom | head -c 20)" || true
        [ "${#pw}" -eq 20 ] || continue
        case "${pw}" in *[[:upper:]]*) ;; *) continue ;; esac
        case "${pw}" in *[[:lower:]]*) ;; *) continue ;; esac
        case "${pw}" in *[[:digit:]]*) ;; *) continue ;; esac
        printf '%s\n' "${pw}"
        return 0
    done
    echo "[nextcloud/passwords] could not draw a password from /dev/urandom" >&2
    return 1
}

nc_password_dir() {
    local dir
    if [ -z "${HOME:-}" ] || [ ! -d "${HOME}" ]; then
        echo "[nextcloud/passwords] HOME is not an existing folder, so ~/nextcloud-passwords has no place to go" >&2
        return 1
    fi
    dir="${HOME}/nextcloud-passwords"
    if [ -e "${dir}" ] && [ ! -d "${dir}" ]; then
        echo "[nextcloud/passwords] ~/nextcloud-passwords exists and is not a folder" >&2
        return 1
    fi
    if ! (umask 077 && mkdir -p -- "${dir}") || ! chmod 700 -- "${dir}"; then
        echo "[nextcloud/passwords] could not make ~/nextcloud-passwords with mode 700" >&2
        return 1
    fi
    printf '%s\n' "${dir}"
}

nc_write_private_file() {
    local name="${1:-}" dir path
    case "${name}" in
        '' | . | .. | */*)
            echo "[nextcloud/passwords] '${name}' is not a plain file name" >&2
            return 1
            ;;
    esac
    dir="$(nc_password_dir)" || return 1
    path="${dir}/${name}"
    # Nothing may be at the path yet. noclobber alone is not enough: when the target exists and
    # is not a regular file (a link to /dev/null, a FIFO), bash skips O_EXCL and opens it, and
    # opening a FIFO blocks until someone reads it.
    if [ -e "${path}" ] || [ -L "${path}" ]; then
        echo "[nextcloud/passwords] will not write ~/nextcloud-passwords/${name}: something is already there" >&2
        return 1
    fi
    # noclobber makes the redirection fail instead of truncating, and O_EXCL under it stops a link
    # that appeared since the check, even one that points nowhere, from being written through.
    if ! (set -o noclobber; umask 077; : > "${path}") 2> /dev/null; then
        echo "[nextcloud/passwords] will not write ~/nextcloud-passwords/${name}: it exists, or cannot be made" >&2
        return 1
    fi
    # The file is ours from here on. chmod covers a default ACL on the folder, which
    # umask does not.
    if ! chmod 600 -- "${path}" || ! cat >> "${path}"; then
        rm -f -- "${path}"
        echo "[nextcloud/passwords] could not write ~/nextcloud-passwords/${name}" >&2
        return 1
    fi
    # Whatever is there now must still be the plain file this call made. If it is not, something
    # replaced it, and it is not ours to remove.
    if [ ! -f "${path}" ] || [ -L "${path}" ]; then
        echo "[nextcloud/passwords] ~/nextcloud-passwords/${name} is not a plain file after the write" >&2
        return 1
    fi
}
