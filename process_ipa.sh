#!/bin/bash
INFILE=""
OUTFILE=""
RENAME_APP=""
NEW_BUNDLE_ID=""
STRIP_BETA=false
STRIP_PROVISIONAL=false
VERBOSE=false
ZIP_FLAGS="-q"
UNZIP_FLAGS="-q"
function print_help {
	echo "usage: process_ipa.sh"
	echo "-i ipa input"
	echo "-o ipa output"
	echo "-r rename app to a new name"
	echo "-R change bundle id"
	echo "-b strip beta status"
	echo "-p strip provisioning profiles"
	echo "-h display this help"
	echo "-v verbose"
	exit 0
}

while getopts "i:o:r:R:hbpv" OPTION
do
	case $OPTION in 
	i)
		INFILE=$OPTARG
		;;
	o)
		OUTFILE=$OPTARG
		;;
	r)
		RENAME_APP=$OPTARG
		;;
	R)
		NEW_BUNDLE_ID=$OPTARG
		;;
	b)
		STRIP_BETA=true
		;;
	p)
		STRIP_PROVISIONAL=true
		;;
	h)
		print_help
		;;
	v)
		VERBOSE=true
		;;
	*)
		print_help
		;;
	esac
done

if $VERBOSE
then
	ZIP_FLAGS=""
	UNZIP_FLAGS=""
fi

if [ "$INFILE" == "" ] || [ "$OUTFILE" == "" ]
then
	echo "please supply -i and -o for ipa input and output"
	print_help
fi

if [ "$INFILE" == "$OUTFILE" ]
then
	echo "input file should not be the same as the out file, for safety"
	exit 1
fi

if [ -e "$OUTFILE" ]
then 
	echo "$OUTFILE exists"
	exit 1
fi

if ! [ -e "$INFILE" ]
then
	echo "$INFILE does not exist"
	exit 1
fi

WORKING_DIR="/tmp/$(uuidgen)"
while [ -e "$WORKING_DIR" ]
do
	WORKING_DIR="/tmp/$(uuidgen)"
done

mkdir $WORKING_DIR
echo extracting ipa content
unzip $UNZIP_FLAGS -d $WORKING_DIR "$INFILE" 
if ! [ -e "$WORKING_DIR/Payload" ]
then
	echo "$INFILE is not a valid ipa"
	if $VERBOSE
	then
		ls $WORKING_DIR
	fi
	rm -rf $WORKING_DIR
	exit 1
fi

APP_DIR="$(ls $WORKING_DIR/Payload | grep -E '.app$')"
if [ "$APP_DIR" == "" ]
then
	echo "$INFILE is not a valid ipa"
	if $VERBOSE
	then
		ls $WORKING_DIR/Payload
	fi
	rm -rf $WORKING_DIR
	exit 1
fi
APP_NAME="$(echo $APP_DIR | sed -e 's/\.app//g')"

LDID_REPLACE=""
LDID_REPLACE_WITH=""

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$WORKING_DIR/Payload/$APP_DIR/Info.plist")"
echo processing $BUNDLE_ID
if [ "$NEW_BUNDLE_ID" != "" ]
then
	echo changing bundle id on Info.plist
	if $VERBOSE
	then
		echo $NEW_BUNDLE_ID
	fi
	/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $NEW_BUNDLE_ID" "$WORKING_DIR/Payload/$APP_DIR/Info.plist"
	LDID_REPLACE=$BUNDLE_ID
	LDID_REPLACE_WITH=$NEW_BUNDLE_ID
	if [ -e "$WORKING_DIR/Payload/$APP_DIR/PlugIns" ]
	then
		ls "$WORKING_DIR/Payload/$APP_DIR/PlugIns" | while read -r LINE
		do
			echo chainging bundle id on $LINE/Info.plist
			EXT_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$WORKING_DIR/Payload/$APP_DIR/PlugIns/$LINE/Info.plist")"
			NEW_EXT_BUNDLE_ID="$(echo $EXT_BUNDLE_ID | sed -e "s/$BUNDLE_ID/$NEW_BUNDLE_ID/g")"
			if $VERBOSE
			then
				echo $NEW_EXT_BUNDLE_ID
			fi
			/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $NEW_EXT_BUNDLE_ID" "$WORKING_DIR/Payload/$APP_DIR/PlugIns/$LINE/Info.plist"
		done
	fi
fi

if [ "$RENAME_APP" != "" ]
then
	echo renaming application
	/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $RENAME_APP" "$WORKING_DIR/Payload/$APP_DIR/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleName $RENAME_APP" "$WORKING_DIR/Payload/$APP_DIR/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $RENAME_APP" "$WORKING_DIR/Payload/$APP_DIR/Info.plist"
fi

function ldid_replace_and_strip_beta {
	TARGET_FILE=$1
	echo stripping beta status of $TARGET_FILE
	XML_FILE="/tmp/$(uuidgen).xml"
	while [ -e $XML_FILE ]
	do
			XML_FILE="/tmp/$(uuidgen).xml"
	done
	END_REACHED=false
	LINE_SKIP=false
	ldid -e "$TARGET_FILE" | while read -r LINE
	do
		if $END_REACHED
		then
			break
		fi
		if $LINE_SKIP
		then
			LINE_SKIP=false
			continue
		fi
		if [ "$(echo $LINE | grep beta-reports-active)" != "" ] && $STRIP_BETA
		then
			LINE_SKIP=true
			continue
		fi
		if [ "$(echo $LINE | grep /plist)" != "" ]
		then
			END_REACHED=true
		fi
		if [ "$LDID_REPLACE" != "" ] && [ "$LDID_REPLACE_WITH" != "" ]
		then
			LINE="$(echo $LINE | sed -e s/$LDID_REPLACE/$LDID_REPLACE_WITH/g)"
		fi
		echo $LINE >> $XML_FILE
		if $VERBOSE
		then
			echo $LINE
		fi
	done
	ldid -S$XML_FILE "$TARGET_FILE"
	rm $XML_FILE
}

if $STRIP_BETA || [ "$NEW_BUNDLE_ID" != "" ]
then
	echo processing binary signatures
	ldid_replace_and_strip_beta "$WORKING_DIR/Payload/$APP_DIR/$APP_NAME"
	if [ -e "$WORKING_DIR/Payload/$APP_DIR/PlugIns/" ]
	then
		ls "$WORKING_DIR/Payload/$APP_DIR/PlugIns/" | while read -r EXT_DIR
		do
			EXT_NAME="$(echo $EXT_DIR | sed -e 's/\.appex//g')"
			ldid_replace_and_strip_beta "$WORKING_DIR/Payload/$APP_DIR/PlugIns/$EXT_DIR/$EXT_NAME"
		done
	fi
fi

ORIG_DIR="$PWD"
cd $WORKING_DIR
TEMP_ZIP_NAME="/tmp/$(uuidgen).zip"
while [ -e /tmp/$TEMP_ZIP_NAME ]
do
	TEMP_ZIP_NAME="/tmp/$(uuidgen).zip"
done

if [ "$RENAME_APP" != "" ]
then
	mv "$WORKING_DIR/Payload/${APP_NAME}.app" "$WORKING_DIR/Payload/${RENAME_APP}.app"
	mv "$WORKING_DIR/Payload/${RENAME_APP}.app/$APP_NAME" "$WORKING_DIR/Payload/${RENAME_APP}.app/$RENAME_APP" 
fi

echo packing new ipa
zip $ZIP_FLAGS -9 -r $TEMP_ZIP_NAME .

if $STRIP_PROVISIONAL
then
	echo stripping provisioning profiles
	find * | grep embedded.mobileprovision | while read -r LINE
	do
		zip $ZIP_FLAGS -d $TEMP_ZIP_NAME "$LINE"
	done
fi

cd "$ORIG_DIR"
mv $TEMP_ZIP_NAME "$OUTFILE"
rm -rf $WORKING_DIR
