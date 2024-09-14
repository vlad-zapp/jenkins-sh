_initJenkins() {
    local JENKINS_SCRIPT_URL="$(echo $1 | grep -Eo 'http(s)?://.[^/]*')"
    local JENKINS_SCRIPT_CREDS="$2"
    local JENKINS_SCRIPT_CMD="$3"

    if [[ -z "$JENKINS_SCRIPT_URL" || -z "$JENKINS_SCRIPT_CREDS" ]]; then
        echo "Usage: source jenkins.sh <server_url> <username:password> [new command name]"
        return 1
    fi

    if [[ -z "$JENKINS_SCRIPT_CMD" ]]; then
        JENKINS_SCRIPT_CMD="jenkins"
    fi

    eval "$JENKINS_SCRIPT_CMD() { _jenkins "$JENKINS_SCRIPT_URL" "$JENKINS_SCRIPT_CREDS" \"\${@}\"; }"
    eval "_${JENKINS_SCRIPT_CMD}_complete() { local word=\"\${COMP_WORDS[\$COMP_CWORD]}\"; _jenkins_complete \"$JENKINS_SCRIPT_URL\" \"$JENKINS_SCRIPT_CREDS\" \"\$word\" \"\${COMP_WORDS[@]:1}\"; }"

    export -f "$JENKINS_SCRIPT_CMD"
    export -f "_${JENKINS_SCRIPT_CMD}_complete"

    _jenkins_complete() {
        while IFS=$'\n' read -r term; do
            if [[ ! -z "$term" ]]; then
                COMPREPLY+=("$term")
                #echo "$term" >&2
            fi
        done <<<"$(_jenkins "$1" "$2" completion "${@:3}")"
    }

    complete -r "$JENKINS_SCRIPT_CMD" 2>/dev/null
    complete -F "_${JENKINS_SCRIPT_CMD}_complete" "$JENKINS_SCRIPT_CMD"
}

# Usage _jenkins <url> <auth> <command> <arguments> [flags]
_jenkins() { (
    set -e
    server="$(echo "$1" | sed -r 's/\/$//g')"
    creds="$2"
    serverId="$(echo "$server" | sed -r "s/[\/:]+/-/g")"
    cacheFile="/tmp/jenkins-cache.$serverId.json"

    request() {
        curl --silent --user "$creds" -g "${@:2}" "$1"
    }

    normalizePath() {
        local jobUrl
        if [[ "$1" =~ ^http(s)?:// ]]; then
            # support direct links to builds on the server
            if [[ "$1" == "$server"* ]]; then
                echo "$1"
            else
                echo "Wrong server in the address. Should be \"$server\"" >&2
                return 1
            fi
        else
            # and common addressing
            local jobLocator="$(echo "$1" | sed -r 's/\/+/\//g' | sed -r 's/^([^\/])/\/\1/g' | sed -r 's/\/$//g')"
            echo "$server$(echo "$jobLocator" | jq -Rr 'split("/")|map(@uri)|join("/job/")')"
        fi
    }

    hasFlag() {
        for arg in "${@:2}"; do
            if [[ "$arg" == "--$1" ]]; then
                return 0
            fi
        done
        return 1
    }

    getFlags() {
        local filtered=()
        for arg in "$@"; do
            if [[ "$arg" == --* ]]; then
                filtered+=("$arg")
            fi
        done
        echo ${filtered[@]}
    }

    withoutFlags() {
        local filtered=()
        for arg in "$@"; do
            if [[ ! "$arg" == --* ]]; then
                filtered+=("$arg")
            fi
        done
        echo ${filtered[@]}
    }

    api-get() {
        request "$1/api/json"
    }

    api-script() {
        request "$server/scriptText" --data-urlencode "script=$1"
    }

    job-build() {
        local jobUrl="$1"

        echo "- Building job \"$jobUrl\"" >&2
        set +x
        local currentBuildId=$(request "$jobUrl/lastBuild/api/json" | jq '.id' -r 2>/dev/null)
        
        # if no prior builds
        if [ -z "$currentBuildId" ]; then
            currentBuildId=0
        fi

        local parameters="$(jq -n '{"parameter":[$ARGS.positional[] | select(.!=null and .!="")] | map({"name":(.|split("=")[0]),"value":(.|split("=")[1:]|join("="))})}' --compact-output --args $(withoutFlags ${@:2}))"

        if hasFlag "enter-params" "$@"
        then
            #set -x
            local interactiveParameters='{"parameter":[]}'
            local paramDefinitions="$(api-get "$jobUrl" | jq '.property[] | select(._class=="hudson.model.ParametersDefinitionProperty") | .parameterDefinitions | map({name:.name,type:.type,default:.defaultParameterValue.value}) | .[]' -c)"
            while read -r l <&3
            #for l in "$paramDefinitions"
            do
                local name="$(echo "$l" | jq -r '.name')"
                local default="$(echo "$l" | jq -r '.default')"
                local type="$(echo "$l" | jq -r '.type')"

                local providedValue="$(echo "$parameters" | jq ".parameter[] | select(.name==\"$name\") | .value" -r)"
                if [ ! -z "$providedValue" ]
                then
                    default="$providedValue"
                fi

                read -p "Enter \"$name\" [$default]: " val
                if [[ -z "$val" ]]
                then
                    val="$default" 
                fi
                interactiveParameters="$(echo "$interactiveParameters" | jq ".parameter += [{name:\"$name\",value:\"$val\"}]")"
            set +x
            done 3<<<"$paramDefinitions"
            parameters="$interactiveParameters"
        fi

        httpCode="$(request "$jobUrl/build?delay=0sec" \
            -X POST \
            -H "Content-Type:application/x-www-form-urlencoded" \
            --data-urlencode "json=$parameters" \
            --write-out "%{http_code}" --silent --output /dev/null)"

        if [[ $httpCode -eq "409" ]]
        then
            echo "Error: looks like the job is disabled"
            return 1
        fi

        job-wait "$jobUrl" "$currentBuildId" $(getFlags "${@:2}")
    }

    job-rebuild() {
        # | sed -nr "s/(.*\/job\/[^\/]+)+\/([0-9]+|last[^\/]+).*/\2/gp" - build
        # | sed -nr "s/((.*\/job\/[^\/]+)+).*/\2/gp - job
        local jobUrl="$(echo "$1" | sed -nr "s/((.*\/job\/[^\/]+)+).*/\2/gp")"
        local build="$(echo "$1" | sed -nr "s/(.*\/job\/[^\/]+)+\/([0-9]+|last[^\/]+).*/\2/gp")"
        if [[ -z "$build" ]]; then build="lastBuild"; fi

        echo -n "- Rebuilding job " >&2
        local jobDetails=$(request "$jobUrl/$build/api/json")
        local json="$(echo $jobDetails | jq --compact-output '{parameter:[ .actions.[] | select(.parameters!=null) | .parameters[] | {name:.name, value:.value} ]}')"
        echo "\"$(echo $jobDetails | jq '.fullDisplayName')\"" >&2

        local currentBuildId=$(request "$jobUrl/lastBuild/api/json" | jq '.id' -r)

        # try to retrigger using gerrit first
        httpCode=$(request "$jobUrl/$build/gerrit-trigger-retrigger-this/index" \
            -X POST \
            --write-out '%{http_code}' --silent --output /dev/null)

        if [[ "$httpCode" -eq "404" ]]; then
            # if there's no gerrit trigger - do a normal build
            httpCode="$(request "$jobUrl/build?delay=0sec" \
                -X POST \
                -H "Content-Type:application/x-www-form-urlencoded" \
                --data-urlencode "json=$json" \
                --write-out "%{http_code}" --silent --output /dev/null)"

            if [[ $httpCode -eq "409" ]]
            then
                echo "Error: looks like the job is disabled"
                return 1
            fi
        elif [[ "$httpCode" -eq "200" ]]; then
            echo "This build is already retriggered and running. Gerrit plugin does not support 2 at a time. Try again later." >&2
            return 1
        fi
        job-wait "$jobUrl" "$currentBuildId" "$(getFlags "${@:2}")"
    }

    job-wait() {
        local jobUrl="$1"
        local currentBuildId="$2"

        echo "- Finding new build of $jobUrl" >&2
        local currentUserName="$(request "$server/me/api/json" | jq '.fullName' -r)"

        while true; do
            local newBuilds=$(echo "$(api-get "$jobUrl")" | jq -r ".builds[] | select(.number>$currentBuildId) | .number")
            while read -r number; do
                if [[ -z "$number" ]]; then
                    continue
                fi
                local buildUrl="$jobUrl/$number"
                local users=$(request "$buildUrl/api/json" | jq '.actions[] | select(.causes!=null) | .causes[] | select(.userName!=null) | .userName' -r)
                if grep -qx "$currentUserName" <<<$users; then
                    if hasFlag "watch" "${@:3}"; then
                        echo "- Getting console output" >&2
                        echo >&2
                        job-console "$jobUrl" "$number"
                        echo "---" >&2
                        echo "More info: $buildUrl" >&2
                    elif hasFlag "wait" "${@:3}"; then
                        echo -n "- Waiting for completion: " >&2
                        echo "$buildUrl" >&2

                        while true; do
                            local inProgress=$(request "$buildUrl/api/json" | jq -r ".inProgress")
                            if [[ "$inProgress" = 'false' ]]; then
                                echo
                                break
                            fi
                            echo -n "." >&2
                            sleep 3
                        done
                    else
                        echo "- Found $buildUrl" >&2
                    fi
                    return
                fi
            done <<<"$newBuilds"
        done
    }

    job-get-config() {
        local jobUrl="$1"
        request "$jobUrl/config.xml" | xmlstarlet fo -n 2>/dev/null
    }

    job-set-config() {
        local jobUrl="$1"
        local config="$2"
        request "$jobUrl/config.xml" -X POST --header "Content-Type:application/xml" --data-binary "$config"
    }

    job-config-get-code() {
        local config="$1"
        echo "$config" | xmlstarlet sel -t -m "//script" -v . -n 2>/dev/null | xmlstarlet unesc
    }

    job-update() {
        local jobUrl="$1"
        local currentConfig="$(job-get-config "$jobUrl")"
        local pipelineCode="$(job-config-get-code "$currentConfig")"
        local newConfig="$currentConfig"

        for object in "${@:2}"; do
            if [[ "$object" = *"@"* ]]; then
                local lib="${object%%@*}"
                local version="${object##*@}"
                local libraryDef="$(echo "$pipelineCode" | grep -Eo "@Library\(.*?$lib.*?\)")"
                pipelineCode="${pipelineCode//"$libraryDef"/@Library(\"$object\")}"

                if ! echo "$pipelineCode" | grep -q "$object"; then
                    local libraryDef="@Library(\"$object\")"
                    # Had to add import statement because jenkins CPS have problems processing next command after @Library.
                    # And the import is known to be safe.
                    pipelineCode=$(echo "$libraryDef import groovy.lang.*" && echo "$pipelineCode")
                    echo "- New library definition added: $libraryDef" >&2
                else
                    echo "- Using updated library definition: \"$object\"" >&2
                fi
            elif [[ "$object" != "--"* ]]
            then
                if [[ ! -f "$object" ]]
                then
                    echo "File \"$object\" is not found" >&2
                    return 1
                fi
                pipelineCode="$(cat "$object")"
                echo "- Replaced pipeline code with: $object" >&2
            fi
        done

        local newConfig="$(echo "$currentConfig" | xmlstarlet ed -u "//script" -v "$pipelineCode" 2>/dev/null | xmlstarlet fo -n 2>/dev/null)"
        if [ "$newConfig" != "$currentConfig" ]; then
            echo "- Updating pipeline job \"$jobUrl\"" >&2
            job-set-config "$jobUrl" "$newConfig"
            if hasFlag "approve" "${@}"
            then
                job-approve "$jobUrl"
            fi
        else
            echo "- No updates were made for the pipeline job \"$jobUrl\"" >&2
        fi
    }

    job-approve() {
        local jobPathGroovy="$(api-get "$1" | jq '.fullName' -r)"
        echo "- Approving pipeline job: $jobPathGroovy"

        local approveScript="
                configText = Jenkins.instance.getItemByFullName('$jobPathGroovy').getConfigFile().asString()
                scriptText = new XmlSlurper().parseText(configText).definition.script.toString()
                scriptText = scriptText.replace('\r\n', '\n') // match unix line endings used by jenkins
                def scriptApproval = org.jenkinsci.plugins.scriptsecurity.scripts.ScriptApproval.get()
                scriptApproval.preapprove(scriptText, org.jenkinsci.plugins.scriptsecurity.scripts.languages.GroovyLanguage.get())
                scriptApproval.save()
                println '[DONE_WITHOUT_ERRORS]'
                return"
        local result="$(api-script "$approveScript")"
        if [ $result=="[DONE_WITHOUT_ERRORS]" ]
        then
            return
        else
            echo "[ERROR] Unable to approve job '$jobPathGroovy' because: $result"
            return 1
        fi
    }

    job-console() {
        local buildUrl="$1/$2"
        local start=0
        while true; do
            local resp=$(request "$buildUrl/logText/progressiveText?start=$start" -w "\n\n%header{X-More-Data}\n%header{X-Text-Size}" |
                sed -r ''s/\\[Pipeline\\]/$(printf '\033[32m[Pipeline]\033[0m')/g'')
            echo -n "$resp" | tail -r | tail -n+4 | tail -r

            start=$(echo "$resp" | tail -n1)
            local more=$(echo "$resp" | tail -n2 | head -n1)

            # most reliable way because it can withstand most of temporary http 500s
            if [[ -z "$more" && ! -z "$start" ]]; then
                return
            fi
        done
    }

    jobs-cache() {
        if [[ "$1" == "--force" ]]; then
            rm -f "$cacheFile.lock"
            rm -f "$cacheFile"
        fi

        # 50 levels deep cache
        touch "$cacheFile.lock"
        param="$(jq -rRn '([range(50)] | map("jobs[fullName") | join(",")) + ([range(50)] | map("]") | join(""))')"
        request "$server/api/json?tree=$param" | jq --arg date $(date +%s) '. += {date:$date}' >"$cacheFile"
        
        # local script="
        #     Jenkins.instance.getJobNames().each { println it }
        #     return
        # "
        # api-script "$script" > "$cacheFile"

        rm "$cacheFile.lock"
    }

    gen-dequote() {
        local word="$1"
        local quote="$(echo "$1" | grep -Eo "^['\"]")"
        echo "$word" | sed "s/^$quote//" | sed "s/$quote$//"
    }

    gen-complete() {
        # echo "$3"
        # set -x
        local quote="$(echo "$1" | grep -Eo "^['\"]")"
        local word="$(gen-dequote "$1")"
        # local quote="$(echo "$1" | grep -Eo "^['\"]")"
        # word="${word#"$quote"}"

        shift

        #echo "quote:$quote" >&1

        for arg in $@; do
            if [[ "$arg" == "$word"* || -z "$word" ]]; then
                echo "$quote$arg$quote"
            fi
        done
        # set +x
    }

    # usage
    if [[ -z "$3" ]]; then
        echo "Usage:"
        echo "get <job path | job url>"
        echo "build <job path | job url> [param1=name1 param2=name2 ...] [flags]"
        echo "rebuild <job path | build url> [build number(if job path was provided)] [flags]"
        echo "seed <seed file path(relative)> <gerrit refspec> [flags]"
        echo "update-pipeline <job path | job url> [ path to groovy file | "LibraryName@NewRevision" ...]"
        echo "approve <job path | job url>"
        echo
        echo "Flags:"
        echo "--wait : Wait until job is finished and return"
        echo "--watch : Stream job output into console and return when job is finished"
    fi

    # process command
    case $3 in
    get)
        local jobPath="$(normalizePath "$4")"
        api-get "$jobPath"
        ;;
    build)
        local jobPath="$(normalizePath "$4")"
        job-build "$jobPath" "${@:5}"
        ;;
    rebuild)
        local jobPath="$(normalizePath "$4")"
        job-rebuild "$jobPath" "${@:5}"
        ;;
    wait)
        local jobPath="$(normalizePath "$4")"
        job-rebuild "$jobPath" "${@:5}"
        ;;
    update-pipeline)
        local jobPath="$(normalizePath "$4")"
        job-update "$jobPath" "${@:5}"
        ;;
    seed)
        local folder="$(dirname "$4")"
        local host="$(cd "$folder" && git remote get-url origin | sed -r 's/.*\:\/\/(.*@)?([^\/^:]*).*\/(.*)/\2/g')"
        local project="$(cd "$folder" && git remote get-url origin | sed -r 's/.*\:\/\/(.*@)?([^\/^:]*).*\/(.*)/\3/g')"
        job-build "$(normalizePath "cicd/SuperSeed")" \
            "SEED_PATH=$4" \
            "RELEASE_FILE_PATH=" \
            "GERRIT_REFSPEC=$5" \
            "GERRIT_BRANCH=" \
            "GERRIT_HOST=$host" \
            "GERRIT_PROJECT=$project" \
            "${@:6}"
        ;;
    approve)
        local jobPath="$(normalizePath "$4")"
        job-approve "$jobPath" "${@:5}"
        ;;
    script)
        api-script "$4"
        echo
        ;;
    cache)
        jobs-cache --force
        ;;
    get-jobs)
        jobs-cache --force
        cat "$cacheFile" | jq '.. | select(._class? | contains("Folder") | not) | .fullName | select(.!=null)' -r
        ;;
    #internal logic for shell auto completion
    completion)
        local words=("${@:5}")
        local currentWord="$4"

        isCurrentWord() {
            for i in "${!words[@]}"; do
                if [[ "${words[$i]}" == "$currentWord" && "$i" -eq "$1" ]]; then
                    return 0
                fi
            done
            return 1
        }

        if isCurrentWord 0; then
            gen-complete "$currentWord" "approve" "get" "get-jobs" "build" "rebuild" "seed" "update-pipeline" "script"

        elif isCurrentWord 1; then
            if [[ ! -f "$cacheFile" ]]; then
                jobs-cache --force
            fi

            while true
                do
                local selector="$(gen-dequote "$currentWord" | jq -Rr 'match("([^\/].*)[\/]").captures[0].string | split("/") | map("select(.fullName | split(\"/\") | last | .==\""+.+"\" ).jobs[] | ") | join("")')"
                IFS=$'\n' declare -a terms="$( cat "$cacheFile" | jq -r ".jobs[] | $selector .fullName+if ._class | endswith(\"Folder\") then \"/\" else \"\" end")"
                complete="$(IFS=$'\n' gen-complete "$currentWord" "${terms[@]}")"

                if [[ $(echo "$complete" | wc -l) -gt 1 || $(echo "$complete" | grep -Eo "[^\/^\"^'][\"']?$") ]]
                then
                    echo "$complete"
                    break
                elif [ ! -z "$complete" ]
                then
                    currentWord="$complete"
                else
                    echo "$currentWord"
                    break
                fi
            done

            # local currentPath="$(echo "$currentWord" | sed -r 's/\/?[^\/]*$//g' | sed -r 's/^([^\/])/\/\1/')"
            # local resp_words="$(request "$(normalizePath "$currentPath")/api/json?tree=jobs[fullName]" | jq -r '.jobs[] | .fullName+if ._class | endswith("Folder") then "/" else "" end')"
            # IFS=$'\n' gen-complete "$currentWord" "${resp_words[@]}"
        fi
        ;;
    *)
        echo Unknown command "$3"
        return 1
    ;;
    esac
) }

export -f _jenkins
export -f _initJenkins

_initJenkins "$@"
