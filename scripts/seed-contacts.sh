#!/bin/bash
# Seed the emulator's address book with a few contacts so CallNote has
# something to show in its contact picker.
#
#   Batman     5550100
#   Joker      5550200
#   Alfred     5550300
#
# The contacts provider stores the display name in the `data` table
# (mimetype name), NOT as a `name` column on raw_contacts - binding `name`
# to raw_contacts fails with "table raw_contacts has no column named name".
# Idempotent: a phone number that already exists is left alone.
set -u
ADB=/workspaces/android-sdk/platform-tools/adb

number_exists() {
  timeout 20 $ADB shell content query --uri content://com.android.contacts/data \
    --projection data1 --where "mimetype='vnd.android.cursor.item/phone_v2' AND data1='$1'" \
    2>/dev/null | grep -q "data1=$1"
}

seed_one() {
  local name="$1" number="$2"
  if number_exists "$number"; then
    echo "$name already present ($number)"
    return 0
  fi

  timeout 20 $ADB shell content insert --uri content://com.android.contacts/raw_contacts \
    --bind account_name:s:CallNote --bind account_type:s:CallNote >/dev/null 2>&1

  local id
  id=$(timeout 20 $ADB shell content query --uri content://com.android.contacts/raw_contacts \
        --projection _id 2>/dev/null | tr -d '\r' | sed -n 's/.*_id=\([0-9]*\).*/\1/p' | tail -1)
  if [ -z "$id" ]; then
    echo "FAILED to create $name (no raw contact id)"
    return 1
  fi

  timeout 20 $ADB shell content insert --uri content://com.android.contacts/data \
    --bind raw_contact_id:i:"$id" \
    --bind mimetype:s:vnd.android.cursor.item/name \
    --bind data1:s:"$name" >/dev/null 2>&1

  timeout 20 $ADB shell content insert --uri content://com.android.contacts/data \
    --bind raw_contact_id:i:"$id" \
    --bind mimetype:s:vnd.android.cursor.item/phone_v2 \
    --bind data1:s:"$number" --bind data2:s:2 --bind data3:s:"$name" >/dev/null 2>&1

  echo "$name created (id $id, $number)"
}

seed_one "Batman" "5550100"
seed_one "Joker"  "5550200"
seed_one "Alfred" "5550300"

echo "--- address book now ---"
timeout 20 $ADB shell content query --uri content://com.android.contacts/contacts \
  --projection display_name 2>/dev/null | tr -d '\r' | head -10
