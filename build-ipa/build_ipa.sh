#!/bin/bash

function realpath {
	if [[ "$1" == /* ]]; then
		echo "$1"
	else
		echo "$PWD/${1#./}"
	fi
}

function fileexists {
	if [ ! -f "$1" ]; then
		echo "Unable to open $1"
		exit 1
	fi
}

if [ "$#" -ne 2 ]; then
	echo "Usage: $0 <MechDome app.zip> <provisioning profile> <entitlements>"
	exit 1
fi

APP_PATH=$(realpath "$1")
PROV_PROFILE_PATH=$(realpath "$2")

fileexists "$APP_PATH"
fileexists "$PROV_PROFILE_PATH"

BUILDS_DIR=`mktemp -d 2>/dev/null || mktemp -d -t 'mytmpdir'`
pushd "$BUILDS_DIR" > /dev/null

#################### Gathering information about codesigning identity,TeamID ####################
unzip "$APP_PATH" >/dev/null
pushd "$BUILDS_DIR/Payload"  >/dev/null
BUNDLE_NAME=$(ls | grep *.app)
PACKAGE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$BUILDS_DIR/Payload/$BUNDLE_NAME/Info.plist")"
EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$BUILDS_DIR/Payload/$BUNDLE_NAME/Info.plist")"
popd >/dev/null

`openssl smime -inform der -in "$PROV_PROFILE_PATH" -verify -out "$BUILDS_DIR/profile.plist"` 2>/dev/null >/dev/null
if [[ ! -f  "$BUILDS_DIR/profile.plist" ]]; then
	echo "Invalid provisioningprofile $PROV_PROFILE_PATH"
	exit 1;
fi
/usr/libexec/PlistBuddy -c 'Print :Entitlements' -x "$BUILDS_DIR/profile.plist" > "$BUILDS_DIR/entitlements.plist" 
DEV_PROFILE_TYPE="$(/usr/libexec/PlistBuddy -c 'Print get-task-allow' "$BUILDS_DIR/entitlements.plist")"
############FOR DEVELOPMENT PROFILES ABOVE COMMAND YIELDS TRUE, SO BASED ON THAT WE WILL REMOVE OR ADD FEW KEY IN ENTITLEMENTS.PLIST
TEAM_ID="$(/usr/libexec/PlistBuddy -c 'Print com.apple.developer.team-identifier' "$BUILDS_DIR/entitlements.plist")"
if [[ "$TEAM_ID" == "" ]]; then
	echo "Can't Sign App without valid development embedded.provisioningprofile";
	exit 1;
fi
/usr/libexec/PlistBuddy -c "Print com.apple.developer.icloud-services" "$BUILDS_DIR/entitlements.plist"  2>/dev/null >/dev/null
exitCode=$? 
if [[ $exitCode == 0 ]]; then # OK
	/usr/libexec/PlistBuddy -c "Set com.apple.developer.ubiquity-kvstore-identifier $TEAM_ID.$PACKAGE_NAME" "$BUILDS_DIR/entitlements.plist"  2>/dev/null 
	
	/usr/libexec/PlistBuddy -c "Delete com.apple.developer.icloud-services CloudDocuments" "$BUILDS_DIR/entitlements.plist"  2>/dev/null 
	/usr/libexec/PlistBuddy -c "Add com.apple.developer.icloud-services array" "$BUILDS_DIR/entitlements.plist"  2>/dev/null
	/usr/libexec/PlistBuddy -c "Add com.apple.developer.icloud-services:0 string CloudDocuments" "$BUILDS_DIR/entitlements.plist"  2>/dev/null

	/usr/libexec/PlistBuddy -c "Delete com.apple.developer.icloud-container-environment" "$BUILDS_DIR/entitlements.plist"  2>/dev/null
	/usr/libexec/PlistBuddy -c "Delete com.apple.developer.icloud-container-development-container-identifiers" "$BUILDS_DIR/entitlements.plist"  2>/dev/null 
fi

if [ "$DEV_PROFILE_TYPE" == "false" ]; then
	security find-identity -v | grep "iPhone Distribution:" > "$BUILDS_DIR/identities.txt"
else
	security find-identity -v | grep "iPhone Developer:" > "$BUILDS_DIR/identities.txt"
fi

declare -a SIGNING_IDS
declare -a SIGNING_SHA1
let j=0;
while read -r line || [[ -n "$line" ]]; do
	if [[ ${#line} -gt 0 ]]; then
		line=${line##*( )}
		#echo "###### $line"
		y=$(echo $line | awk '{print $2}')
		#echo "------> $y"
		SIGNING_SHA1[$j]="$y";
		let start=-1
		let count=0;
		for (( i=0; i<${#line}; i++ )); do

	        if [ "${line:$i:1}" == '"' ]; then
	                if [ $start -eq -1 ]; then
	                        start=$i;
	                        ((count++));
	                else
	                        SIGNING_IDS[$j]=$(echo "${line:$start:$count}");
	                        break;
	                fi
	        fi

	        if [ $count -gt 0 ]; then
	                ((count++));
	        fi
		done
    	((j++));
	fi
done < "$BUILDS_DIR/identities.txt"
if [ ! "${#SIGNING_IDS[@]}" -gt 0 ] ; then
	echo "No sigining identities found, please install a development certificate";
	exit 1;
fi


let SIGNING_IDENTITY
if [[ "${#SIGNING_IDS[@]}" -eq 1 ]]; then
	DISPLAY_SIGNING_IDENTITY="${SIGNING_IDS[0]}"
	SIGNING_IDENTITY="${SIGNING_SHA1[0]}"
	echo "Code signing identity is $DISPLAY_SIGNING_IDENTITY";
	#echo "SHA1 signing identity is $SIGNING_IDENTITY";
else
	echo ""
	echo "Please select a signing identity from below list"
	let COUNT=0;
	let ADD=1
	for i in "${SIGNING_IDS[@]}"
	do
		COUNT=$(echo $((COUNT+1)))
		echo "$COUNT" "-" "$i"
	done
	echo ""
	printf ">"
	while read -r NUM; do
		if [[ $NUM -lt 1 || $NUM -gt "${#SIGNING_IDS[@]}" ]]; then
			echo "";
			echo "Please select correct index"
			continue;
		else
			break;
		fi
	done

	let Index=$NUM-1;
	DISPLAY_SIGNING_IDENTITY="${SIGNING_IDS[$Index]}"
	SIGNING_IDENTITY="${SIGNING_SHA1[$Index]}"
	echo "";
	echo "Code signing identity is $DISPLAY_SIGNING_IDENTITY";
	#echo "SHA1 signing identity is $SIGNING_IDENTITY";
fi

cd - >/dev/null
##########################################################################################

cp "$PROV_PROFILE_PATH" "$BUILDS_DIR/Payload/$BUNDLE_NAME/embedded.mobileprovision" >/dev/null
codesign --force --sign "$SIGNING_IDENTITY" -i "$PACKAGE_NAME" --entitlements "$BUILDS_DIR/entitlements.plist" --timestamp=none "$BUILDS_DIR/Payload/$BUNDLE_NAME"

cd "$BUILDS_DIR" >/dev/null
find . -name '.DS_Store' -type f -delete >/dev/null
zip -9r "$EXECUTABLE_NAME".zip "Payload" >/dev/null
mv "$BUILDS_DIR/$EXECUTABLE_NAME.zip" "$BUILDS_DIR/$EXECUTABLE_NAME.ipa" >/dev/null
rm -rf "$BUILDS_DIR/Payload"
find . \! -name '*.ipa' -type f -delete

popd >/dev/null

echo""
if [ -f "$BUILDS_DIR/$EXECUTABLE_NAME.ipa" ]; then
	mv "$BUILDS_DIR/$EXECUTABLE_NAME.ipa" .
	echo "App $EXECUTABLE_NAME.ipa is ready to install"
else	
	echo "Error signing app $EXECUTABLE_NAME"
fi

rm -rf $BUILDS_DIR
