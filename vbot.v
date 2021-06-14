import terisback.discordv as discord
import net.http
import os
import x.json2
import strings
import arrays
import json
import regex

const (
	bot_token = os.getenv('VBOT_TOKEN')
	user = os.getenv('ISOLATE_USER')
	vexeroot = @VEXEROOT
	block_size = 4096
	inode_ratio = 16384
)

struct State {
	headers []string
}

fn main() {
	os.execute("isolate --cleanup")

	mut client := discord.new(token: bot_token) ?
	client.userdata = &State{load_docs_headers()}
	client.on_message_create(on_message)
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
			else { return error("Illegal character.") }
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

	content := os.read_file('$vexeroot/doc/docs.md') or { panic(err) }

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

fn on_message(mut client discord.Client, message &discord.Message) {
	content := message.content
	mut re := regex.regex_opt(r"/run ```[a-z]*\s+(.*)```") or { panic(err.msg) }
	start, _ := re.match_string(content)
	
	if start != -1 {
		roles := message.member.roles
		mut authorized := false

		// v-dev, moderator, owner
		for role in ["671405628023111731", "592107317705703427", "595009999227453444"] {
			if role in roles {
				authorized = true
			}
		}

		if !authorized {
			client.channel_message_send(message.channel_id, content: "You aren't authorized to use eval.") or {}
			return
		}
		
		group := re.get_group_list()[0]
		code := content[group.start..group.end]
		resp := "```\n${run_in_sandbox(code)}\n```"
		client.channel_message_send(message.channel_id, content: resp) or {}
	}
}

fn run_in_sandbox(code string) string {
	iso_res := os.execute("isolate --init")
	defer { 
		os.execute("isolate --cleanup") 
	}
	box_path := os.join_path(iso_res.output.trim_suffix("\n"), "box")
	os.write_file(os.join_path(box_path, "code.v"), code) or {
		return "Failed to write code to sandbox."
	}
	run_res := os.execute("su $user -c 'sudo isolate --dir=$vexeroot --env=HOME=/box --processes=3 --mem=100000 --wall-time=5 --quota=${1048576 / block_size},${1048576 / inode_ratio} --run $vexeroot/v run code.v'")
	return prettify(run_res.output)
}

fn prettify(output string) string  {
	mut pretty := output

	if pretty.len > 1992 {
		pretty = pretty[..1989] + "..."
	}

	nlines := pretty.count("\n")
	if nlines > 5 {
		pretty = pretty.split_into_lines()[..5].join_lines() + "\n...and ${nlines - 5} more"
	}

	return pretty
}
