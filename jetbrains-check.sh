#!/usr/bin/bash

TMPFILE="/tmp/jetbrains.xml"
if [[ ! -f "$TMPFILE" ]]; then
  touch /tmp/jetbrains.xml
  curl -s --location --header "Accept: application/rdf+xml" "https://www.jetbrains.com/updates/updates.xml" >"$TMPFILE"
fi

VERSION=$(xmllint --xpath "string(/products/product[@name='$1']/channel[@status='release' or @status!='eap']/build/@version)" "$TMPFILE")
FULLNUMBER=$(xmllint --xpath "string(/products/product[@name='$1']/channel[@status='release' or @status!='eap']/build/@fullNumber)" "$TMPFILE")

echo "$VERSION"+"$FULLNUMBER"
