#!/usr/bin/env bash

####################################################################
# START of GitHub Action specific code

# This script assumes that node, curl, sudo, python and jq are installed.

# If you want to run this script in a non-GitHub Action environment,
# all you'd need to do is set the following environment variables and
# delete the code below. Everything else is platform independent.
#
# Here, we're translating the GitHub action input arguments into environment variables
# for this script to use.
[[ -n "$INPUT_STORE" ]]             && export SHOP_STORE="$INPUT_STORE"
[[ -n "$INPUT_PASSWORD" ]]          && export SHOP_PASSWORD="$INPUT_PASSWORD"
[[ -n "$INPUT_PRODUCT_HANDLE" ]]    && export SHOP_PRODUCT_HANDLE="$INPUT_PRODUCT_HANDLE"
[[ -n "$INPUT_COLLECTION_HANDLE" ]] && export SHOP_COLLECTION_HANDLE="$INPUT_COLLECTION_HANDLE"
[[ -n "$INPUT_THEME_ROOT" ]]        && export THEME_ROOT="$INPUT_THEME_ROOT"
[[ -n "$INPUT_PULL_THEME" ]]        && export SHOP_PULL_THEME="$INPUT_PULL_THEME"

# Authentication creds
export SHOP_ACCESS_TOKEN="$INPUT_ACCESS_TOKEN"

# Authentication creds (deprecated)
[[ -n "$INPUT_APP_ID" ]]               && export SHOP_APP_ID="$INPUT_APP_ID"
[[ -n "$INPUT_APP_PASSWORD" ]]         && export SHOP_APP_PASSWORD="$INPUT_APP_PASSWORD"

# Optional, these are used by Lighthouse CI to add pass/fail checks on
# the GitHub Pull Request.
[[ -n "$INPUT_LHCI_GITHUB_APP_TOKEN" ]] && export LHCI_GITHUB_APP_TOKEN="$INPUT_LHCI_GITHUB_APP_TOKEN"
[[ -n "$INPUT_LHCI_GITHUB_TOKEN" ]]     && export LHCI_GITHUB_TOKEN="$INPUT_LHCI_GITHUB_TOKEN"

# Optional, these are used
[[ -n "$INPUT_LHCI_MIN_SCORE_PERFORMANCE" ]]   && export LHCI_MIN_SCORE_PERFORMANCE="$INPUT_LHCI_MIN_SCORE_PERFORMANCE"
[[ -n "$INPUT_LHCI_MIN_SCORE_ACCESSIBILITY" ]] && export LHCI_MIN_SCORE_ACCESSIBILITY="$INPUT_LHCI_MIN_SCORE_ACCESSIBILITY"

# Add global node bin to PATH (from the Dockerfile)
export PATH="$PATH:$npm_config_prefix/bin"

# END of GitHub Action Specific Code
####################################################################

# Portable code below
set -eou pipefail

log() {
  echo "$@" 1>&2
}

step() {
  cat <<-EOF 1>&2
	==============================
	$1
	EOF
}

is_installed() {
  # This works with scripts and programs. For more info, check
  # http://goo.gl/B9683D
  type $1 &> /dev/null 2>&1
}

api_request() {
  local url="$1"
  local err="$(mktemp)"
  local out="$(mktemp)"

  set +e
  if [[ -n "$SHOP_ACCESS_TOKEN" ]]; then
    curl -sS -f -X GET \
      "$url" \
      -H "X-Shopify-Access-Token: ${SHOP_ACCESS_TOKEN}" \
      1> "$out" \
      2> "$err"
  else
    local username="$SHOP_APP_ID"
    local password="$SHOP_APP_PASSWORD"
    curl -sS -f -X GET \
      -u "$username:$password" "$url" \
      1> "$out" \
      2> "$err"
  fi
  set -e

  local exit_code="$?"
  local errors="$(cat "$out" | jq '.errors')"

  if [[ $exit_code != '0' ]]; then
    log "There's been a curl error when querying the API"
    cat "$err" 1>&2
    return 1
  elif [[ $errors != 'null' ]]; then
    log "There's been an error when querying the API"
    log "$errors"
    cat "$err" 1>&2
    return 1
  fi

  cat "$out"
}

cleanup() {
  if [[ -n "${theme+x}" ]]; then
    step "Disposing development theme"
    shopify theme delete -d -f
    shopify logout
  fi

  if [[ -f "lighthouserc.yml" ]]; then
    rm "lighthouserc.yml"
  fi

  if [[ -f "setPreviewCookies.js" ]]; then
    rm "setPreviewCookies.js"
  fi

  return $1
}

trap 'cleanup $?' EXIT

if ! is_installed lhci; then
  step "Installing Lighthouse CI"
  log npm install -g @lhci/cli@0.7.x puppeteer
  npm install -g @lhci/cli@0.7.x puppeteer
fi

if ! is_installed shopify; then
  step "Installing Shopify CLI"
  log "gem install shopify"
  gem install shopify
fi

step "Configuring shopify CLI"

# Disable analytics
mkdir -p ~/.config/shopify && cat <<-YAML > ~/.config/shopify/config
[analytics]
enabled = false
YAML

# Secret environment variable that turns shopify CLI into CI mode that accepts environment credentials
export CI=1
export SHOPIFY_SHOP="${SHOP_STORE#*(https://|http://)}"

if [[ -n "$SHOP_ACCESS_TOKEN" ]]; then
  export SHOPIFY_PASSWORD="$SHOP_ACCESS_TOKEN"
else
  export SHOPIFY_PASSWORD="$SHOP_APP_PASSWORD"
fi

shopify login

host="https://${SHOP_STORE#*(https://|http://)}"
theme_root="${THEME_ROOT:-.}"

# Use the $SHOP_PASSWORD defined as a Github Secret for password protected stores.
[[ -z ${SHOP_PASSWORD+x} ]] && shop_password='' || shop_password="$SHOP_PASSWORD"

log "Will run Lighthouse CI on $host"

step "Creating development theme"

if [[ -n "${SHOP_PULL_THEME+x}" ]]; then
  log "Pulling settings from theme $SHOP_PULL_THEME"
  shopify theme pull $theme_root --theme ${SHOP_PULL_THEME} --only templates/*.json --only config/settings_data.json
fi

theme_push_log="$(mktemp)"
shopify theme push --development --json $theme_root > "$theme_push_log" && cat "$theme_push_log"
preview_url="$(cat "$theme_push_log" | tail -n 1 | jq -r '.theme.preview_url')"
preview_id="$(cat "$theme_push_log" | tail -n 1 | jq -r '.theme.id')"

step "Configuring Lighthouse CI"

if [[ -n "${SHOP_PRODUCT_HANDLE+x}" ]]; then
  product_handle="$SHOP_PRODUCT_HANDLE"
else
  log "Fetching product handle"
  product_response="$(api_request "$host/admin/api/2021-04/products.json?published_status=published&limit=1")"
  product_handle="$(echo "$product_response" | jq -r '.products[0].handle')"
  log "Using $product_handle"
fi

if [[ -n "${SHOP_COLLECTION_HANDLE+x}" ]]; then
  collection_handle="$SHOP_COLLECTION_HANDLE"
else
  log "Fetching collection handle"
  collection_response="$(api_request "$host/admin/api/2021-04/custom_collections.json?published_status=published&limit=1")"
  collection_handle="$(echo "$collection_response" | jq -r '.custom_collections[0].handle')"
  log "Using $collection_handle"
fi

# Disable redirects + preview bar
query_string="?preview_theme_id=${preview_id}&_fd=0&pb=0"
min_score_performance="${LHCI_MIN_SCORE_PERFORMANCE:-0.6}"
min_score_accessibility="${LHCI_MIN_SCORE_ACCESSIBILITY:-0.9}"

cat <<- EOF > lighthouserc.yml
ci:
  collect:
    numberOfRuns: 1
    url:
      - "$host/$query_string"
      - "$host/products/$product_handle$query_string"
      - "$host/collections/$collection_handle$query_string"
    puppeteerScript: './setPreviewCookies.js'
    puppeteerLaunchOptions:
      args:
        - "--no-sandbox"
        - "--disable-setuid-sandbox"
        - "--disable-dev-shm-usage"
        - "--disable-gpu"
  upload:
    target: filesystem
    outputDir: ./reports
  assert:
    assertions:
      "categories:performance":
        - error
        - minScore: 0.1
          aggregationMethod: median-run
      "categories:accessibility":
        - error
        - minScore: 0.1
          aggregationMethod: median-run
EOF

cat <<-EOF > setPreviewCookies.js
module.exports = async (browser) => {
  // launch browser for LHCI
  console.error('Getting a new page...');
  const page = await browser.newPage();
  // Get password cookie if password is set
  if ('$shop_password' !== '') {
    console.error('Getting password cookie...');
    await page.goto('$host/password$query_string');
    await page.waitForSelector('form[action*=password] input[type="password"]');
    await page.\$eval('form[action*=password] input[type="password"]', input => input.value = '$shop_password');
    await Promise.all([
      page.waitForNavigation(),
      page.\$eval('form[action*=password]', form => form.submit()),
    ])
  }
  // Get preview cookie
  console.error('Getting preview cookie...');
  await page.goto('$preview_url');
  // close session for next run
  await page.close();
};
EOF

log "Running lighthouse Step 1"

step "Running Lighthouse CI"
lhci autorun

git remote -v
 
step "Opening the report file"
cat /github/workspace/reports/manifest.json

# Function to extract JSON data from the files and create the desired structure
extract_json_data() {
    # Read the manifest.json file and extract its content
    manifest=$(cat /github/workspace/reports/manifest.json)

    # Get the event name or action URL
    if [ "$GITHUB_EVENT_NAME" == "pull_request" ]; then
        event_info="Pull Request Link: $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/pull/$GITHUB_EVENT_NUMBER"
    else
        event_info="Event Name: $GITHUB_EVENT_NAME, Action URL: $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
    fi

    # Initialize an array to store the data
    data_array=()

    # Loop through all the .json files in /github/workspace/reports/ directory (excluding manifest.json)
    for file in /github/workspace/reports/*.json; do
        # Skip manifest.json
        if [ "$(basename "$file")" == "manifest.json" ]; then
            continue
        fi

        # Get the page type based on the filename
        if [[ $file == *"collections"* ]]; then
            page_type="Collection Page"
        elif [[ $file == *"products"* ]]; then
            page_type="Product Page"
        else
            page_type="Homepage"
        fi

        # Extract the JSON data from the file
        json_data=$(cat "$file")

        # Extract the required fields from the json_data
	requestedUrl=$(echo "$json_data" | jq -r '.requestedUrl')
	finalUrl=$(echo "$json_data" | jq -r '.finalUrl')
 	fcp=$(echo "$json_data" | jq -r '.audits."first-contentful-paint".displayValue')
	lcp=$(echo "$json_data" | jq -r '.audits."largest-contentful-paint".displayValue')
	tbt=$(echo "$json_data" | jq -r '.audits."total-blocking-time".displayValue')
	cls=$(echo "$json_data" | jq -r '.audits."cumulative-layout-shift".displayValue')
	si=$(echo "$json_data" | jq -r '.audits."speed-index".displayValue')
	performance=$(echo "$manifest" | jq --arg finalUrl "$finalUrl" '.[] | select(.url == $finalUrl) | .summary.performance')
	
        # Replace the .json extension with .html to get the corresponding HTML file path
        html_file="${file%.json}.html"

        # Read the content of the HTML file and store it in the variable 'html_content'
        html_content=$(cat "$html_file")


    data_entry=$(cat <<-EOF
        {
            "Page": "$page_type",
            "Requested Url": "$requestedUrl",
            "Performance": $performance,
            "First Contentful Paint": "$fcp",
            "Largest Contentful Paint": "$lcp",
            "Total Blocking Time": "$tbt",
            "Cumulative Layout Shift": "$cls",
            "Speed Index": "$si",
            "Event Info": "$event_info"
        }
EOF
    )

        # Append the data_entry to the data_array
        data_array+=("$data_entry")
    
 	# log "data_array: $data_array"
    done

    # Combine the data_array into a single JSON array
    
    # Join the elements of data_array with commas
    joined_data=$(printf ",%s" "${data_array[@]}")
    joined_data=${joined_data:1}  # Remove the leading comma
	
    # Create a valid JSON array
    json_array="[$joined_data]"
    echo "$json_array"
}


step "Uploading the reports to sheets"

# Function to upload data to Google Sheets using cURL
upload_to_google_sheet() {
    # Read JSON data from file
    data=$(extract_json_data)

    # log "data_to_send: $data"
    
    # Extract only the repository name from $GITHUB_REPOSITORY
    repository_name=$(basename $GITHUB_REPOSITORY)
    
    # Create a JSON object with repository name and data
    json_object="{ \"$repository_name\": $data }"

    # Print the JSON object
    # log "Data to send: $json_object"

    # data=$(cat /github/workspace/reports/manifest.json)
    curl -X POST -H "Content-Type: application/json" -d "$json_object" "https://script.google.com/macros/s/AKfycbyB5ZndlIiVjJvpRpXBWfJvlGrMdjCcohTs5s2J5quzx3FqOn8CsftifHEQPwUdlEBj/exec"
}

# ls /github/workspace/reports/

# Call the function to upload data to Google Sheet
upload_to_google_sheet


  # Set the personal access token (replace `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` with your actual token)
  ACCESS_TOKEN="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"

step "pwd"
pwd

step "git branch"
git branch

step "git status"
git status

step "git log"
git log

step "number of commits"
commit_count=$(git log --oneline | wc -l)
log "Total number of commits: $commit_count"

step "credentials"
# git config user.name
# git config user.email

step "make a new branch"
git checkout -b test

step "git status"
git status

step "git add"
git add .

step "git commit"
git commit -m 'initial commit'

step "pushing the new branch"
git push origin test "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"






