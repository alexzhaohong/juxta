#!/bin/bash

#
# Takes a list of tweet-IDs
# - Extracts the tweets using  https://github.com/docnow/twarc
# - Extract image-URLs from the tweets
# - Downloads the images
# - Generates a collage using the images with links back to the tweets
#
# The format of the tweet-ID-file is a list of tweetIDs (numbers), one per line
#
# Requirements:
# - An installed twarc and a Twitter API key (see the twarc GitHub readme)
# - jq (sudo apt install jq)
#
# TODO: Consider adding user.screen_name as metadata

###############################################################################
# CONFIG
###############################################################################

: ${TWARC:="/usr/local/bin/twarc"} # Also tries default path
: ${IMAGE_BUCKET_SIZE:=20000}
: ${MAX_IMAGES:=99999999999}
: ${THREADS:=3}
: ${TIMEOUT:=60}
: ${TEMPLATE:="demo_twitter.template.html"}
: ${ALREADY_HYDRATED:=false}
: ${FULLTEXT:=false} # Experimental

: ${RAW_W:=1}
: ${RAW_H:=1}

################################################################################
# FUNCTIONS
################################################################################

usage() {
    echo "./demo_twitter.sh tweet-ID-list [collage_name]"
    exit $1
}

parse_arguments() {
    TWEETIDS="$1"
    if [[ ! -s "$TWEETIDS" ]]; then
        >&2 echo "Error: No tweet-ID-list at '$TWEETIDS'"
        usage 1
    fi
    DEST="$2"
    if [[ "." == ".$DEST" ]]; then
        DEST=$(basename "$TWEETIDS") # foo.json.gz
        DEST="${DEST%.*}" # foo.json
        DEST="twitter_${DEST%.*}" # foo
        echo "No collage name specified, using $DEST"
    fi
    if [[ "." == .$(which jq) ]]; then
        >&2 echo "Error: jq not available. Install with 'sudo apt-get install jq'"
        exit 9
    fi
    export FULLTEXT
}

# Output: HYDRATED
hydrate() {
    export HYDRATED="$DOWNLOAD/hydrated.json.gz"
    
    if [[ "." != .$( grep '{' "$TWEETIDS" | head -n 1 ) ]]; then
        echo "Input file $TWEETIDS contains a '{', so it is probably already hydrated"
        ALREADY_HYDRATED=true
    elif [[ -s "$DOWNLOAD/hydrated.json" ]]; then
        echo " - Skipping hydration of '$TWEETIDS' as $DOWNLOAD/hydrated.json already exists"
        export HYDRATED="$DOWNLOAD/hydrated.json"
        return
    elif [[ -s "$DOWNLOAD/hydrated.json.gz" ]]; then
        echo " - Skipping hydration of '$TWEETIDS' as $DOWNLOAD/hydrated.json.gz already exists"
        return
    fi
    
    if [ "true" == "$ALREADY_HYDRATED" ]; then
        if [[ "$TWEETIDS" == *.gz ]]; then
            echo "Input file $TWEETIDS is already hydrated. Copying to $DOWNLOAD/hydrated.json.gz"
            cp $TWEETIDS $DOWNLOAD/hydrated.json.gz
        else
            echo "Input file $TWEETIDS is already hydrated. GZIPping to $DOWNLOAD/hydrated.json.gz"
            gzip -c $TWEETIDS > $DOWNLOAD/hydrated.json.gz
        fi
        return
    fi
    if [ ! -x "$TWARC" ]; then
        TWARC=$(which twarc)
        if [ ! -x "$TWARC" ]; then
            >&2 echo "Unable to locate twarc executable (tried $TWARC)"
            >&2 echo "Please state the folder using environment variables, such as"
            >&2 echo "TWARC=/home/myself/bin/twarc ./demo_twitter.sh mytweetIDs.dat mytweets"
            exit 3
        fi
    fi
    echo " - Hydration of '$TWEETIDS' to $DOWNLOAD/hydrated.json.gz"
    $TWARC hydrate "$TWEETIDS" | gzip > "$DOWNLOAD/hydrated.json"
}

extract_image_data() {
    # TODO: Better handling of errors than throwing them away
    if [[ "true" == "$FULLTEXT" ]]; then
        if [ -s "$DOWNLOAD/date-id-imageURL.dat" ]; then
            echo " - Skipping extraction of date, ID and imageURL as $DOWNLOAD/date-id-imageURL.dat already exists"
            return
        fi
        echo " - Extracting date, ID and imageURL to $DOWNLOAD/date-id-imageURL.dat"
        zcat "$HYDRATED" | jq --indent 0 -r 'if (.entities .media[] .type) == "photo" then [.id_str,.created_at,.entities .media[] .media_url_https // .entities .media[] .media_url] else empty end' > "$DOWNLOAD/date-id-imageURL.dat" 2>/dev/null
    else
        if [ -s "$DOWNLOAD/date-id-imageURL-fulltext.dat" ]; then
            echo " - Skipping extraction of date, ID, imageURL and fulltext as $DOWNLOAD/date-id-imageURL-fulltext.dat already exists"
            return
        fi
        echo " - Extracting date, ID, imageURL and fulltext to $DOWNLOAD/date-id-imageURL-fulltext.dat"
        zcat "$HYDRATED" | jq --indent 0 -r 'if (.entities .media[] .type) == "photo" then [.id_str,.created_at,(.entities .media[] .media_url_https // .entities .media[] .media_url),.full_text ] else empty end' > "$DOWNLOAD/date-id-imageURL-fulltext.dat" 2>/dev/null
    fi
    # TODO: $DOWNLOAD/hydrated.json -> $DOWNLOAD/date-id-imageURL.dat
}

# 1 ["786532479343599600","Thu Oct 13 11:42:10 +0000 2016","https://pbs.twimg.com/media/CupTGBlWcAA-yzz.jpg"]
# 1 ["786532479343599600","Thu Oct 13 11:42:10 +0000 2016","https://pbs.twimg.com/media/CupTGBlWcAA-yzz.jpg","Some text\nWith newlines"]
download_image() {
    local LINE="$@"
    local IFS=$' '
    local TOKENS=($LINE)
    local COUNT=${TOKENS[0]}
    unset IFS
    LINE="["${LINE#*\[}

    # ["786532479343599600","Thu Oct 13 11:42:10 +0000 2016","https://pbs.twimg.com/media/CupTGBlWcAA-yzz.jpg"]
    # ["786532479343599600","Thu Oct 13 11:42:10 +0000 2016","https://pbs.twimg.com/media/CupTGBlWcAA-yzz.jpg","Some text\nWith newlines"]
    
    local ID=$( jq '.[0]' <<< "$LINE" )
    local DATE_STR=$( jq '.[1]' <<< "$LINE" )
    local TDATE=$( date -d "$DATE_STR" +"%Y-%m-%dT%H:%M:%S" )
    local IMAGE_URL=$( jq '.[2]' <<< "$LINE" )
    local IMAGE_NAME=$(sed -e 's/^[a-zA-Z]*:\/\///' -e 's/[^-A-Za-z0-9_.]/_/g' <<< "$IMAGE_URL")
    if [[ "true" == "$FULLTEXT" ]]; then
        local T_TEXT=$( jq '.[3]' <<< "$LINE" )
    fi

    local BUCKET=$((COUNT / IMAGE_BUCKET_SIZE * IMAGE_BUCKET_SIZE ))
    mkdir -p "$DOWNLOAD/images/$BUCKET"
    local IDEST="$DOWNLOAD/images/$BUCKET/$IMAGE_NAME"
    if [ ! -s "$IDEST" ]; then
        curl -s -m $TIMEOUT "$IMAGE_URL" > "$IDEST"
    fi
    if [ -s "$IDEST" ]; then
        if [[ "true" == "$FULLTEXT" ]]; then
            echo "$COUNT/$MAX $TDATE $ID $IDEST $T_TEXT"
        else
            echo "$COUNT/$MAX $TDATE $ID $IDEST"
        fi
    else
        >&2 echo "Unable to download $IMAGE_URL"
    fi    
}
export -f download_image

download_images() {
    if [ -s "$DOWNLOAD/counter-max-date-id-imagePath.dat" ]; then
        echo " - $DOWNLOAD/counter-max-date-id-imagePath.dat already exists, but all images might not be there"
    fi
    
    echo " - Downloading images defined in $DOWNLOAD/date-id-imageURL.dat"

    # Create job list
    local MAX=`cat "$DOWNLOAD/date-id-imageURL.dat" | wc -l`
    if [ "$MAX_IMAGES" -lt "$MAX" ]; then
        MAX=$MAX_IMAGES
    fi
    local ITMP=`mktemp /tmp/juxta_demo_twitter_XXXXXXXX`
    local COUNTER=1
    IFS=$'\n'
    while read LINE; do
        if [ $COUNTER -gt $MAX ]; then
            break
        fi
        echo "$COUNTER $LINE" >> $ITMP
        COUNTER=$(( COUNTER + 1 ))
    done < "$DOWNLOAD/date-id-imageURL.dat"

    # Run download jobs threaded
    export MAX
    export IMAGE_BUCKET_SIZE
    export DOWNLOAD
    export TIMEOUT
    #cat $ITMP | tr '\n' '\0' | xargs -0 -P $THREADS -n 1 -I {} bash -c 'echo "{}"'
    # TODO: Add synchronization to avoid jumbled output
    if [[ "true" == "$FULLTEXT" ]]; then
        local O="$DOWNLOAD/counter-max-date-id-imagePath.dat"
    else
        local O="$DOWNLOAD/counter-max-date-id-imagePath-fulltext.dat"
    fi
    tr '\n' '\0' <<< "$ITMP" | xargs -0 -P $THREADS -n 1 -I {} bash -c 'download_image "{}"' | tee "$O"
    rm $ITMP
}

prepare_juxta_input() {
    echo " - Sorting and preparing juxta image list $DOWNLOAD/twitter_images.dat"
    # TODO: Enhance split with fulltext
    cat "$DOWNLOAD/counter-max-date-id-imagePath.dat" | sed -e 's/^[0-9\/]* //' -e 's/^\([^ ][^ ]*\) \([0-9][0-9]*\) \([^ ][^ ]*\)$/\3|\2 \1/' > "$DOWNLOAD/twitter_images.dat"
}

###############################################################################
# CODE
###############################################################################

parse_arguments "$@"
DOWNLOAD="${DEST}_downloads"
mkdir -p "$DOWNLOAD"
hydrate
extract_image_data
download_images
prepare_juxta_input

export TEMPLATE
export RAW_W
export RAW_H
export THREADS
INCLUDE_ORIGIN=false ./juxta.sh "$DOWNLOAD/twitter_images.dat" "$DEST"
