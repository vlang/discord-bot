import terisback.discordv as discord
import net.http
import os
import x.json2
import strings
import arrays
import json

const bot_token = os.getenv('VBOT_TOKEN')

struct State {
	headers []string
}

fn main() {
	mut client := discord.new(token: bot_token) ?
	client.userdata = &State{load_docs_headers()}
	client.on_interaction_create(on_interaction)
	client.run().wait()
}

fn reply_to_interaction(data string, id string, token string) {
	url := 'https://discord.com/api/v8/interactions/$id/$token/callback'
	json := '{"type": 4, "data": $data}'
	http.post_json(url, json) or {}
}

fn on_interaction(mut client discord.Client, interaction &discord.Interaction) {
	options := interaction.data.options.map([it.name, it.value])

	match interaction.data.name {
		'vlib' {
			resp := vlib_command(options)
			reply_to_interaction(resp, interaction.id, interaction.token)
		}
		'docs' {
			state := &State(client.userdata)
			resp := docs_command(options, state.headers)
			reply_to_interaction(resp, interaction.id, interaction.token)
		}
		else {}
	}
}

fn sanitize(argument string) ? {
	for letter in argument {
		match letter {
			`0`...`9`, `a`...`z`, `A`...`Z`, `.`, `_` {}
			else { return none }
		}
	}
}

struct Section {
	name string
	content string
	comments []string
}

fn vlib_command(options [][]string) string {
	vlib_module := options[0][1]
	query := options[1][1]
	
	sanitize(vlib_module) or {
		return '{"content": "Only letters, numbers, ., and _ are allowed in module names."}'
	}

	sanitize(query) or {
		return '{"content": "Only letters, numbers, ., and _ are allowed in queries."}'
	}

	result := os.execute('v doc -f json -o stdout $vlib_module')

	if result.exit_code != 0 {
		return '{"content": "Module `$vlib_module` not found."}'
	}

	json := json2.raw_decode(result.output) or {
		return '{"content": "Decoding `v doc` json failed."}'
	}

	mut lowest, mut closest := 2147483647, Section{}
	sections := json.as_map()['contents'].arr()

	for section_ in sections {
		section := section_.as_map()
		name := section["name"].str()
		score := strings.levenshtein_distance(query, name)

		if score < lowest {
			lowest = score
			closest = Section {
				name: name
				content: section["content"].json_str()
				comments: section["comments"].arr().map(it.as_map()["text"].json_str())
			}
		}

		for child_ in section["children"].arr() {
			child := child_.as_map()
			child_name := child["name"].str()
			child_score := strings.levenshtein_distance(query, child_name)

			if child_score < lowest {
				lowest = child_score
				closest = Section {
					name: child_name
					content: child["content"].json_str()
					comments: child["comments"].arr().map(it.as_map()["text"].json_str())
				}
			}
		}
	}

	mut description := '```v\\n$closest.content```'
	mut blob := ''

	for comment in closest.comments {
		blob += comment.trim_left("\u0001")
	}

	if blob != '' {
		description += '\\n>>> $blob'
	}

	return '{
		"embeds": [
			{
				"title": "$vlib_module $closest.name", 
				"description": "$description",
				"url": "https://modules.vlang.io/${vlib_module}.html#$closest.name",
				"color": 4360181
			}
		]
	}'
}

fn load_docs_headers() []string {
	mut headers := []string{}

	content := os.read_file('$os.home_dir()/.v/doc/docs.md') or { panic(err) }

	for line in content.split_into_lines() {
		stripped := line.trim_space()

		if stripped.starts_with('* [') {
			header := stripped[(stripped.index_byte(`(`) + 1)..(stripped.len - 1)]

			if header[0] == `#` {
				headers << header
			}
		}
	}

	return headers
}

fn docs_command(options [][]string, headers []string) string {
	query := '#' + options[0][1]
	scores := headers.map(strings.levenshtein_distance(query, it))
	lowest := arrays.min(scores)
	header := headers[scores.index(lowest)]

	return '{"content": "<https://github.com/vlang/v/blob/master/doc/docs.md$header>"}'
}
