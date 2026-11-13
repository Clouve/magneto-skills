#!/usr/bin/env bash
# SuiteCRM skill: users.sh
#
# SuiteCRM's users, roles and security groups, through SuiteCRM's own code (remote/users.php, run in the
# SuiteCRM container as the web user). It prints JSON on stdout and its messages on stderr. It never takes,
# makes or prints a password: temp-password.sh gives an account a temporary one in a private file,
# `users.sh invite` has SuiteCRM email its own, and restore-admin-password.sh puts the main admin's back.
#
# Usage:
#   users.sh list
#   users.sh show <login>
#   users.sh invite <login> --last-name NAME --email ADDR [--first-name NAME] [--admin --yes-admin] --yes-send
#   users.sh deactivate <login>
#   users.sh activate <login>
#   users.sh set-admin <login> yes --yes-admin
#   users.sh set-admin <login> no
#   users.sh password-rule
#   users.sh password-rule first-sign-in --yes-change
#   users.sh role-list
#   users.sh role-show <role>
#   users.sh role-create <role>
#   users.sh role-assign <login> <role>
#   users.sh role-unassign <login> <role>
#   users.sh role-set <role> <Module> <action> <level>
#   users.sh group-list
#   users.sh group-create <group>
#   users.sh group-add <login> <group>
#   users.sh group-remove <login> <group>
#
#   show, list   each account has system_generated_password (true while it is on a password that SuiteCRM or
#                this skill made; it says nothing about whether the person has signed in) and
#                asks_for_new_password (when SuiteCRM will ask that person for a new one, in words).
#   invite       makes the account and has SuiteCRM send its "New account information" email with a password
#                SuiteCRM generates. Nobody else sees that password. When SuiteCRM asks the person for a new
#                one follows the site's rule, which password-rule prints: on a stock install that is 7 days
#                after the password was set, and until then the emailed password keeps working. It sends
#                an email, so it needs --yes-send, and it refuses when outgoing email is not set up. --admin
#                makes an administrator and needs --yes-admin too. Exit 8 means the account was made and
#                the email failed: give it a password with temp-password.sh --yes-reset.
#   deactivate   the account can no longer sign in, and a session it had open ends. Its records stay, still
#                assigned to it. This is what to do when someone leaves; SuiteCRM users are never deleted
#                here. activate takes it back. Both print was_status.
#   set-admin    yes gives the account full control of SuiteCRM: every record whatever its roles, exports,
#                other users' accounts and Module Loader. It needs --yes-admin. no takes the right away and
#                needs no flag. Both print was_admin.
#   password-rule
#                prints when SuiteCRM asks a person on a generated password (a temporary one, or an emailed
#                one) for a new password: "at the first sign-in", "N days after the password was set", "at
#                sign-in number N with that password" or "never". It is one setting for the whole site
#                (Admin > Password Management, "System-Generated Password Expiration"). This skill never
#                changes it by itself. `password-rule first-sign-in --yes-change` sets it to the first
#                sign-in and prints the rule before and after.
#   role-set     sets what a role may do in one module, and prints the level it replaced (before, after).
#                <action> is access, view, list, edit, delete, import, export or massupdate. <level> is
#                enabled or disabled for access; all, group, owner or none for view, list, edit, delete and
#                export; all or none for import and massupdate (SuiteCRM has no owner level for those two);
#                default clears the setting, and a setting that is not there means allowed. The module is
#                named as in its address: Accounts, Contacts, Leads, Opportunities, Cases and so on. When
#                the new level lets more through than the old one, the note says so.
#   role-assign, role-unassign, group-add, group-remove
#                print the person's roles or groups before and after (roles_before, roles_after,
#                groups_before, groups_after).
#
# The deployment's main admin (SUITECRM_ADMIN_USER) can't be deactivated or lose its admin rights here.
#
# Env vars read: SUITECRM_ADMIN_USER (the main admin's login), SUITECRM_HOST (through run-in-suitecrm.sh).
#
# Exit codes: 0 done; 64 usage, or a yes flag is missing (nothing was changed); 65 bad input; 2 refused (the
# main admin, an account that signs in elsewhere, no email set up) or SuiteCRM did not keep the change; 3 no
# such user, role, group or action; 4 it exists already; 8 invited but the email was not sent; 70, 75, 255
# from run-in-suitecrm.sh.

set -uo pipefail

usage() {
    cat <<'USAGE'
Usage: users.sh list | show <login>
       users.sh invite <login> --last-name NAME --email ADDR [--first-name NAME] [--admin --yes-admin] --yes-send
       users.sh deactivate <login> | activate <login>
       users.sh set-admin <login> yes --yes-admin | set-admin <login> no
       users.sh password-rule | password-rule first-sign-in --yes-change
       users.sh role-list | role-show <role> | role-create <role>
       users.sh role-assign <login> <role> | role-unassign <login> <role>
       users.sh role-set <role> <Module> <action> <level>
       users.sh group-list | group-create <group> | group-add <login> <group> | group-remove <login> <group>

SuiteCRM's users, roles and security groups. Prints JSON. It never handles a password: use temp-password.sh
for a temporary one in a private file, invite for SuiteCRM's own emailed one (sends mail: --yes-send), and
restore-admin-password.sh for the main admin.

Making an administrator needs --yes-admin (set-admin yes, invite --admin). Every change prints what it
replaced: was_status, was_admin, roles_before, groups_before, and before and after for role-set.

password-rule prints when SuiteCRM asks a person on a generated password for a new one. On a stock install
that is 7 days after the password was set, and until then the generated password keeps working. It is one
setting for the whole site; password-rule first-sign-in --yes-change sets it to the first sign-in.

role-set: <action> is access, view, list, edit, delete, import, export or massupdate; <level> is enabled or
disabled for access; all, group, owner or none for view, list, edit, delete and export; all or none for
import and massupdate; default to clear it (a setting that is not there means allowed).

Exit codes: 0 done; 64 usage or a yes flag is missing; 65 bad input; 2 refused or not kept; 3 not found;
4 exists already; 8 invited but no email went out; 70 the script crashed; 75 SuiteCRM is being installed or
upgraded; 255 ssh failed.
USAGE
}

msg() { printf '[suitecrm/users] %s\n' "$*" >&2; }
usage_error() {
    msg "$1"
    usage >&2
    exit 64
}

# The runner's php form says which script of the skill called it.
export SC_SKILL_CALLER=users.sh

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
run=("${script_dir}/run-in-suitecrm.sh" php users.php)
main="${SUITECRM_ADMIN_USER:--}"

admin_refusal="It gives the account full control of SuiteCRM: every record whatever its roles, exports, other users' accounts and Module Loader, which runs code on the server."

action="${1:-}"
[ "$#" -gt 0 ] && shift
case "${action}" in
    -h | --help) usage; exit 0 ;;
    '') usage_error "no action given" ;;
    list | role-list | group-list)
        [ "$#" -eq 0 ] || usage_error "${action} takes no arguments"
        exec "${run[@]}" "${action}"
        ;;
    show | activate | role-show | role-create | group-create)
        [ "$#" -eq 1 ] && [ -n "$1" ] || usage_error "${action} takes one name"
        exec "${run[@]}" "${action}" "$1"
        ;;
    deactivate)
        [ "$#" -eq 1 ] && [ -n "$1" ] || usage_error "deactivate takes one login"
        exec "${run[@]}" deactivate "$1" "${main}"
        ;;
    set-admin)
        { [ "$#" -eq 2 ] || [ "$#" -eq 3 ]; } && [ -n "$1" ] || usage_error "set-admin takes a login and yes or no"
        case "$2" in yes | no) ;; *) usage_error "set-admin takes yes or no" ;; esac
        yes_admin=0
        if [ "$#" -eq 3 ]; then
            [ "$3" = --yes-admin ] || usage_error "unknown option for set-admin: $(printf '%q' "$3")"
            yes_admin=1
        fi
        if [ "$2" = yes ] && [ "${yes_admin}" -ne 1 ]; then
            msg "nothing was changed. This makes $(printf '%q' "$1") an administrator. ${admin_refusal} It can be taken back with: users.sh set-admin $(printf '%q' "$1") no. What the account read or exported in between stays read. Show that to the user, and run it again with --yes-admin after a clear yes."
            exit 64
        fi
        exec "${run[@]}" set-admin "$1" "$2" "${main}"
        ;;
    password-rule)
        if [ "$#" -eq 0 ]; then
            exec "${run[@]}" password-rule
        fi
        [ "$1" = first-sign-in ] || usage_error "password-rule takes nothing, or first-sign-in"
        if [ "$#" -ne 2 ] || [ "$2" != --yes-change ]; then
            [ "$#" -le 2 ] || usage_error "password-rule first-sign-in takes only --yes-change"
            [ "$#" -eq 1 ] || usage_error "unknown option for password-rule: $(printf '%q' "$2")"
            msg "nothing was changed. This changes a rule for the whole site: SuiteCRM would ask everyone who is on a generated password (a temporary one from temp-password.sh, or one it emailed) for a new password at their next sign-in, now and from here on. users.sh password-rule shows the rule as it is and who is on a generated password. It can be changed back under Admin > Password Management in SuiteCRM (System-Generated Password Expiration). Show that to the user, and run it again with --yes-change after a clear yes."
            exit 64
        fi
        exec "${run[@]}" password-rule first-sign-in
        ;;
    role-assign | role-unassign | group-add | group-remove)
        [ "$#" -eq 2 ] && [ -n "$1" ] && [ -n "$2" ] || usage_error "${action} takes a login and a name"
        exec "${run[@]}" "${action}" "$1" "$2"
        ;;
    role-set)
        [ "$#" -eq 4 ] || usage_error "role-set takes <role> <Module> <action> <level>"
        case "$3" in
            access | view | list | edit | delete | import | export | massupdate) ;;
            *) usage_error "the action must be access, view, list, edit, delete, import, export or massupdate" ;;
        esac
        case "$4" in
            all | group | owner | none | enabled | disabled | default) ;;
            *) usage_error "the level must be all, group, owner, none, enabled, disabled or default" ;;
        esac
        exec "${run[@]}" role-set "$1" "$2" "$3" "$4"
        ;;
    invite)
        [ "$#" -ge 1 ] && [ -n "$1" ] || usage_error "invite takes a login"
        login="$1"
        shift
        first='' last='' email='' admin=0 yes=0 yes_admin=0
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --first-name) [ "$#" -ge 2 ] || usage_error "$1 needs a value"; first="$2"; shift 2 ;;
                --last-name) [ "$#" -ge 2 ] || usage_error "$1 needs a value"; last="$2"; shift 2 ;;
                --email) [ "$#" -ge 2 ] || usage_error "$1 needs a value"; email="$2"; shift 2 ;;
                --admin) admin=1; shift ;;
                --yes-send) yes=1; shift ;;
                --yes-admin) yes_admin=1; shift ;;
                *) usage_error "unknown option for invite: $(printf '%q' "$1")" ;;
            esac
        done
        [ -n "${last}" ] || usage_error "invite needs --last-name"
        [[ "${email}" =~ ^[^[:space:]@]+@[^[:space:]@]+$ ]] || usage_error "invite needs --email with an address like name@example.com"
        if [ "${admin}" -eq 0 ] && [ "${yes_admin}" -eq 1 ]; then
            usage_error "--yes-admin goes with --admin"
        fi
        if [ "${admin}" -eq 1 ] && [ "${yes_admin}" -ne 1 ]; then
            msg "nothing was done. This makes the account $(printf '%q' "${login}") as an administrator and has SuiteCRM email a generated password to ${email}. ${admin_refusal} It can be taken back with users.sh set-admin $(printf '%q' "${login}") no, or users.sh deactivate. Show that to the user, and run it again with --yes-admin and --yes-send after a clear yes."
            exit 64
        fi
        if [ "${yes}" -ne 1 ]; then
            msg "nothing was done. This makes the account ${login} and has SuiteCRM email a generated password to ${email}. Show that to the user, and run it again with --yes-send after a clear yes."
            exit 64
        fi
        exec "${run[@]}" invite "${login}" "${first}" "${last}" "${email}" "${admin}"
        ;;
    *) usage_error "unknown action: $(printf '%q' "${action}")" ;;
esac
