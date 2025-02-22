#! /bin/bash
# Set default values for sprint and points when those fields are unset
# Usage:
# ./set-points-and-sprint.sh \
#  --url "https://github.com/HHS/simpler-grants-gov/issues/123" \
#  --org "HHS" \
#  --project 13 \
#  --sprint-field "Sprint" \
#  --points-field "Points" \
#  --dry-run # allows users to run in dry run mode


# #######################################################
# Parse command line args with format `--option arg`
# #######################################################

# see this stack overflow for more details:
# https://stackoverflow.com/a/14203146/7338319
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)
      echo "Running in dry run mode"
      dry_run=YES
      shift # past argument
      ;;
    --url)
      issue_url="$2"
      shift # past argument
      shift # past value
      ;;
    --org)
      org="$2"
      shift # past argument
      shift # past value
      ;;
    --project)
      project="$2"
      shift # past argument
      shift # past value
      ;;
    --sprint-field)
      sprint_field="$2"
      shift # past argument
      shift # past value
      ;;
    --points-field)
      points_field="$2"
      shift # past argument
      shift # past value
      ;;
    -*|--*)
      echo "Unknown option $1"
      exit 1
      ;;
    *)
      POSITIONAL_ARGS+=("$1") # save positional arg
      shift # past argument
      ;;
  esac
done

# #######################################################
# Set script-specific variables
# #######################################################

mkdir -p tmp
raw_data_file="tmp/closed-issue-data-raw.json"
item_data_file="tmp/closed-issue-data.json"
field_data_file="tmp/field-data.json"
item_query=$(cat "queries/getItemMetadata.graphql")
field_query=$(cat "queries/getFieldMetadata.graphql")

# #######################################################
# Fetch issue metadata
# #######################################################

gh api graphql \
 --header 'GraphQL-Features:issue_types' \
 --field url="${issue_url}" \
 --field sprintField="${sprint_field}" \
 --field pointsField="${points_field}" \
 -f query="${item_query}" > $raw_data_file

# #######################################################
# Isolate the correct project item and issue type
# #######################################################

# Get project item
jq ".data.resource.projectItems.nodes[] |

 # filter for the item in the given project
 select(.project.number == ${project}) |

 # filter for items with the sprint or points fields unset
 select (.sprint == null or .points == null or .points.number == 0) |

 # format the output
 {
   itemId,
   projectId: .project.projectId,
   sprint: .sprint.iterationId,
   points: .points.number,
 }
 " $raw_data_file > $item_data_file  # read from raw and write to item_data_file

# Get issue type
issue_type=$(jq -r ".data.resource.issueType.name" $raw_data_file)

# Get PR author (if PR is linked to issue)
pr_author=$(
  jq -r '.data.resource.pullRequests.nodes |
  if length > 0 then .[0].author.login else null end' $raw_data_file
)

# #######################################################
# Assign PR author to issue, or abort update
# #######################################################

# If the issue doesn't have a linked PR, print a message and exit
if [[ $pr_author == 'null' ]]; then
  echo "Issue '$issue_url' wasn't closed by a PR. Skipping further action."
  exit 0

# If the output file for issue data is empty, print a message and exit
elif [[ ! -s $item_data_file ]]; then
  echo "Sprint and story points don't need to be updated. Skipping further action."
  exit 0

# Otherwise add the PR author to the list of assignees and proceed with other updates
else
  if [[ $dry_run == "YES" ]]; then
    echo "Would assign issue ${issue_url} to $pr_author"
  else
    echo "Assigning issue ${issue_url} to $pr_author"
    gh issue edit $issue_url --add-assignee $pr_author
  fi
fi

# #######################################################
# Fetch project metadata
# #######################################################

# If issue is a Task, Bug, or Enhancement, fetch the project metadata
case "${issue_type}" in
"Task"|"Bug"|"Enhancement")
    gh api graphql \
    --field org="${org}" \
    --field project="${project}" \
    --field sprintField="${sprint_field}" \
    --field pointsField="${points_field}" \
    -f query="${field_query}" \
    --jq ".data.organization.projectV2 |

    # reformat the field metadata
    {
      points,
      sprint: {
        fieldId: .sprint.fieldId,
        iterationId: .sprint.configuration.iterations[0].id,
      }
    }" > $field_data_file  # write output to a file
;;

# If it's some other type, print a message and exit
*)
    echo "Not updating because issue has type: ${issue_type}"
    exit 0
;;
esac

# get the itemId and the projectId
item_id=$(jq -r '.itemId' "$item_data_file")
project_id=$(jq -r '.projectId' "$item_data_file")

# #######################################################
# Set the points value, if empty
# #######################################################

if jq -e ".points == null or .points == 0" $item_data_file > /dev/null; then

    if [[ $dry_run == "YES" ]]; then
      echo "Would set points field to 1 for issue: ${issue_url}"
    else
      echo "Setting points field to 1 for issue: ${issue_url}"
      # Get fieldId from field data
      point_field_id=$(jq -r '.points.fieldId' "$field_data_file")
      # Use GitHub CLI to update field
      gh project item-edit \
        --id "${item_id}" \
        --project-id "${project_id}" \
        --field-id "${point_field_id}" \
        --number 1
    fi

else
    echo "Point value already set for issue: ${issue_url}"
fi

# #######################################################
# Set the sprint value, if empty
# #######################################################

if jq -e ".sprint == null" $item_data_file > /dev/null; then

    # Skip actual update in dry-run mode
    if [[ $dry_run == "YES" ]]; then
      echo "Would set sprint field to current sprint for issue: ${issue_url}"
    else
      echo "Setting sprint field to current sprint for issue: ${issue_url}"
      # Get fieldId and iterationId from field data
      sprint_field_id=$(jq -r '.sprint.fieldId' "$field_data_file")
      iteration_id=$(jq -r '.sprint.iterationId' "$field_data_file")
      # Use GitHub CLI to update project field
      gh project item-edit \
        --id "${item_id}" \
        --project-id "${project_id}" \
        --field-id "${sprint_field_id}" \
        --iteration-id "${iteration_id}"
    fi

else
    echo "Sprint value already set for issue: ${issue_url}"
fi
