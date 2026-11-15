#!/bin/bash
# Tests only: a LimeSurvey admin's browser, for the two buttons on the SuiteCRM plugin's settings page. It runs
# inside the LimeSurvey container and signs in over HTTP as tests/crm-kit.test.sh in the magneto repo does.
# Usage: admin-web.sh <admin login> check-status|initialize-oauth2     the admin's password on stdin
# Prints the plugin's JSON answer. Exit 1 when the sign-in or the call failed.
set -u
B=http://127.0.0.1:8080
H=(-H 'Host: localhost')
login="$1"
case "$2" in
    check-status) fn=actionCheckStatus ;;
    initialize-oauth2) fn=actionInitializeOAuth2 ;;
    *) echo "usage: admin-web.sh <admin login> check-status|initialize-oauth2" >&2; exit 64 ;;
esac
dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT
jar="$dir/jar"
# One line on stdin. curl sends the file as it is, so the line break at its end must not be in it.
(umask 077 && head -n 1 | tr -d '\n' > "$dir/pw")
token() { grep -o '<input[^>]*name="YII_CSRF_TOKEN"[^>]*>' "$dir/body" | head -n 1 | sed -E 's/.*value="([^"]*)".*/\1/'; }
curl -s "${H[@]}" -c "$jar" -b "$jar" -o "$dir/body" "$B/index.php/admin/authentication/sa/login" || exit 1
# The password goes to curl from a file, so it is in no command line.
curl -s "${H[@]}" -c "$jar" -b "$jar" -o /dev/null --data-urlencode "YII_CSRF_TOKEN=$(token)" --data-urlencode authMethod=Authdb \
    --data-urlencode "user=$login" --data-urlencode "password@$dir/pw" --data-urlencode loginlang=default \
    --data-urlencode action=login --data-urlencode login_submit=login "$B/index.php/admin/authentication/sa/login" || exit 1
# The token is kept in the session and printed into every admin page as a hidden field.
curl -s "${H[@]}" -c "$jar" -b "$jar" -o "$dir/body" "$B/index.php/admin/pluginmanager/sa/index" || exit 1
tok="$(token)"
[ -n "$tok" ] || { echo "admin-web.sh: the sign-in did not work" >&2; exit 1; }
curl -s "${H[@]}" -c "$jar" -b "$jar" --data-urlencode "YII_CSRF_TOKEN=$tok" "$B/index.php/plugins/direct?plugin=SuiteCRMIntegration&function=$fn"
echo
