import terisback.discordv as discord
import net.http
import os
import x.json2
import strings
import arrays

const bot_token = os.getenv("VBOT_TOKEN")

struct State {
	headers []string
}

fn main() {
	mut client := discord.new(token: bot_token)?
	client.userdata = &State{load_docs_headers()}
	client.on_interaction_create(on_interaction)
	client.run().wait()
}

fn reply_to_interaction(data string, id string, token string) {
	url := "https://discord.com/api/v8/interactions/$id/$token/callback"
	json := '{"type": 4, "data": $data}'
	http.post_json(url, json) or {}
}

fn on_interaction(mut client discord.Client, interaction &discord.Interaction) {
	options := interaction.data.options.map([it.name, it.value])

	match interaction.data.name {
		"vlib" {
			resp := vlib_command(options)
			reply_to_interaction(resp, interaction.id, interaction.token)
		}
		"docs" {
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
			else { return error("") } 
		}
	}
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

	result := os.execute("v doc -f json -o stdout $vlib_module $query")

	if result.exit_code != 0 {
		return '{"content": "Module `$vlib_module` not found."}'
	}

	json := json2.raw_decode(result.output) or {
		return '{"content": "Decoding `v doc` json failed."}'
	}

	sections := json.as_map()["contents"].arr().filter(it.as_map()["name"].str() == query)
			
	if sections.len < 1 {
		return '{"content": "No match found for `$query` in `$vlib_module`."}'
	}

	section := sections[0].as_map()
	code := section["content"].json_str()
	
	mut description := "```v\\n$code```"
	mut blob := ""

	for comment in section["comments"].arr() {
		text := comment.as_map()["text"].json_str()

		if text.len > 1 {
			blob += text[1..]
		}
	}

	if blob != "" {
		description += "\\n>>> $blob"
	}

	return '{
		"embeds": [
			{
				"title": "${vlib_module} $query", 
				"description": "$description",
				"url": "https://modules.vlang.io/${vlib_module}.html#$query",
				"color": 4360181
			}
		]
	}'
}

fn load_docs_headers() []string {
	mut headers := []string{}
	
	content := os.read_file("${os.home_dir()}/.v/doc/docs.md") or { panic(err) }

	for line in content.split_into_lines() {
		stripped := line.trim_space()

		if stripped.starts_with("* [") {
			header := stripped[(stripped.index_byte(`(`) + 1)..(stripped.len - 1)]
			
			if header[0] == `#` {
				headers << header
			}
		}
	}

	return headers
}

fn docs_command(options [][]string, headers []string) string {
	query := "#" + options[0][1]
	scores := headers.map(strings.levenshtein_distance(query, it))
	lowest := arrays.min(scores)
	header := headers[scores.index(lowest)]

	return '{"content": "<https://github.com/vlang/v/blob/master/doc/docs.md$header>"}'
}


