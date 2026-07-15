#!/bin/bash

# Create a mutation for a specific contract, use second parameter as config file name
# Examples:
#    ./certora/mutations/add_mutation.sh liquidityInvariant src/Morpho.sol

add_diff_block() {
    local file="$1"
    local temp_file="./temp_${file##*/}"

    cp "$file" "$temp_file"

    git_diff_block=$(git diff "$file")

    first_change_line_number=$(echo "$git_diff_block" | sed -n '/@@/,/@@/ { s/@@ -\([0-9]*\),[0-9]* .*/\1/p; q; }')

    if [ ! -z "$first_change_line_number" ]; then
        local adjusted_line_number=$((first_change_line_number - 1))
        awk -v n="$adjusted_line_number" -v diff_block="$git_diff_block" 'NR==n {print "\n/**************************** Mutation Diff Block Start ****************************\n"diff_block"\n**************************** Mutation Diff Block End *****************************/\n"} 1' "$temp_file" > temp && mv temp "$temp_file"
    fi

    mv "$temp_file" "$file"
}

MUTATION_DIR_NAME="$1"
CONTRACT_FILEPATH="$2"
MUTATION_NAME="$3"

if [ -z "$MUTATION_DIR_NAME" ] || [ -z "$CONTRACT_FILEPATH" ]; then
    echo "usage:"
    echo "  ./add_mutation.sh [MUTATION_DIR_NAME] [CONTRACT_FILEPATH] [OPTIONAL: MUTATION_NAME]"
    echo "Example:"
    echo "  ./certora/mutations/add_mutation.sh liquidityInvariant src/Morpho.sol"
    echo "  ./certora/mutations/add_mutation.sh liquidityInvariant src/Morpho.sol custom_name"
    exit 0
fi

if [ -z "$MUTATION_NAME" ]; then

    LAST_NUMBER=$(find certora/mutations/${MUTATION_DIR_NAME} -type f -name "*.sol" | awk -F '/' '{print $NF}' | awk -F '.sol' '{print $1}' | sort -n | tail -n 1)

    if [ -z "$LAST_NUMBER" ]; then
        LAST_NUMBER=0
    fi

    NEXT_NUMBER=$((LAST_NUMBER + 1))

    MUTATION_FILENAME="${NEXT_NUMBER}.sol"
else
    MUTATION_FILENAME="${MUTATION_NAME}.sol"
fi

add_diff_block "$CONTRACT_FILEPATH"

cp "$CONTRACT_FILEPATH" "certora/mutations/${MUTATION_DIR_NAME}/${MUTATION_FILENAME}"

git restore "$CONTRACT_FILEPATH"
