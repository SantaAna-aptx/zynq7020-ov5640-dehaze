#!/bin/sh
# ---------------------------------------------------------------------------
#  set.cgi -- write the dehazing parameters for dehaze_web
#
#  The preview page calls this on every slider move:
#      /set.cgi?omega=192&t0=64&gain=269&mode=1
#  and it lands in params.cfg, which dehaze_web re-reads once per frame.
#
#  busybox runs this through the interpreter named in httpd.conf
#  ("*.cgi:/bin/sh"), so it needs neither the executable bit nor a cgi-bin dir.
#
#  The write goes through a temporary file and rename: a half-written params.cfg
#  would be parsed as "some keys kept, some dropped" for one frame, which looks
#  exactly like the sliders not working.
# ---------------------------------------------------------------------------
printf 'Content-Type: text/plain\r\n\r\n'

DIR=/www
TMP="$DIR/params.cfg.tmp"
: > "$TMP"

OLDIFS=$IFS
IFS='&'
for kv in $QUERY_STRING; do
    k=${kv%%=*}
    v=${kv#*=}
    case "$k" in
        omega|t0|gain|mode) ;;
        *) continue ;;
    esac
    case "$v" in
        ''|*[!0-9]*) continue ;;      # digits only
    esac
    echo "$k=$v" >> "$TMP"
done
IFS=$OLDIFS

if [ -s "$TMP" ]; then
    mv "$TMP" "$DIR/params.cfg"
    echo "ok"
else
    rm -f "$TMP"
    echo "no valid keys"
fi
