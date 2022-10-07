package main

import "core:fmt"
import "core:strings"
import "core:mem"
import "core:math/rand"
import "core:strconv"
import "core:container/queue"
import "formats:spall"

find_idx :: proc(events: []Event, val: f64) -> int {
	low := 0
	max := len(events)
	high := max - 1

	for low < high {
		mid := (low + high) / 2

		ev := events[mid]
		ev_start := ev.timestamp - total_min_time
		ev_end := ev_start + ev.duration

		if (val >= ev_start && val <= ev_end) {
			return mid
		} else if ev_start < val && ev_end < val { 
			low = mid + 1
		} else { 
			high = mid - 1
		}
	}

	return low
}

jp: JSONParser
bp: Parser

@export
start_loading_file :: proc "contextless" (size: u32, name: string) {
	context = wasmContext
	init_loading_state(size, name)
	get_chunk(0.0, f64(CHUNK_SIZE))

}

manual_load :: proc(config, name: string) {
	init_loading_state(u32(len(config)), name)
	load_config_chunk(0, u32(len(config)), transmute([]u8)config)
}

set_next_chunk :: proc(p: ^Parser, start: u32, chunk: []u8) {
	p.chunk_start = i64(start)
	p.full_chunk = chunk
}

gen_event_color :: proc(events: []Event, thread_max: f64) -> (FVec3, f64) {
	total_weight : f64 = 0

	color := FVec3{}
	color_weights := [choice_count]f64{}
	for ev in events {
		idx := name_color_idx(in_getstr(ev.name))

		duration := f64(bound_duration(ev, thread_max))
		if duration <= 0 {
			//fmt.printf("weird duration: %d, %#v\n", duration, ev)
			duration = 0.1
		}
		color_weights[idx] += duration
		total_weight += duration
	}

	weights_sum : f64 = 0
	for weight, idx in color_weights {
		color += color_choices[idx] * f32(weight)
		weights_sum += weight
	}
	if weights_sum <= 0 {
		fmt.printf("Invalid weights sum! events: %d, %f, %f\n", len(events), weights_sum, total_weight)
		trap()
	}
	color /= f32(weights_sum)

	return color, total_weight
}

build_tree :: proc(tm: ^Thread, depth_idx: int, events: []Event) -> uint {
	bucket_size :: 8

	bucket_count := i_round_up(len(events), bucket_size) / bucket_size
	max_nodes := bucket_count
	{
		row_count := bucket_count
		parent_row_count := (row_count + (CHUNK_NARY_WIDTH - 1)) / CHUNK_NARY_WIDTH
		for row_count > 1 {
			tmp := (row_count + (CHUNK_NARY_WIDTH - 1)) / CHUNK_NARY_WIDTH
			max_nodes += tmp
			row_count = parent_row_count
			parent_row_count = tmp
		}
	}

	tm.depths[depth_idx].tree = make([dynamic]ChunkNode, 0, max_nodes, big_global_allocator)
	tree := &tm.depths[depth_idx].tree

	for i := 0; i < bucket_count; i += 1 {
		start_idx := i * bucket_size
		end_idx := start_idx + min(len(events) - start_idx, bucket_size)
		scan_arr := events[start_idx:end_idx]

		start_ev := scan_arr[0]
		end_ev := scan_arr[len(scan_arr)-1]

		node := ChunkNode{}
		node.start_time = start_ev.timestamp - total_min_time
		node.end_time   = end_ev.timestamp + bound_duration(end_ev, tm.max_time) - total_min_time
		node.start_idx  = uint(start_idx)
		node.arr_len = i8(len(scan_arr))

		avg_color, weight := gen_event_color(scan_arr, tm.max_time)
		node.avg_color = avg_color
		node.weight = weight

		append(tree, node)
	}

	tree_start_idx := 0
	tree_end_idx := len(tree)

	row_count := len(tree)
	parent_row_count := (row_count + (CHUNK_NARY_WIDTH - 1)) / CHUNK_NARY_WIDTH
	for row_count > 1 {
		for i := 0; i < parent_row_count; i += 1 {
			start_idx := tree_start_idx + (i * CHUNK_NARY_WIDTH)
			end_idx := start_idx + min(tree_end_idx - start_idx, CHUNK_NARY_WIDTH)

			children := tree[start_idx:end_idx]

			start_node := children[0]
			end_node := children[len(children)-1]

			node := ChunkNode{}
			node.start_time = start_node.start_time
			node.end_time   = end_node.end_time
			node.start_idx  = start_node.start_idx

			avg_color := FVec3{}
			for j := 0; j < len(children); j += 1 {
				node.children[j] = uint(start_idx + j)
				avg_color += children[j].avg_color * f32(children[j].weight)
				node.weight += children[j].weight
			}
			node.child_count = i8(len(children))
			node.avg_color = avg_color / f32(node.weight)

			append(tree, node)
		}

		tree_start_idx = tree_end_idx
		tree_end_idx = len(tree)
		row_count = tree_end_idx - tree_start_idx
		parent_row_count = (row_count + (CHUNK_NARY_WIDTH - 1)) / CHUNK_NARY_WIDTH
	}

	//fmt.printf("evs: %d, tree: %d, ratio: %f\n", len(events), len(tree), f64(len(tree)) / f64(len(events)))

	//fmt.printf("tree len: %d, head: %d\n", len(tree), len(tree) - 1)
	return len(tree) - 1
}

print_tree :: proc(tree: []ChunkNode, head: uint) {
	fmt.printf("mah tree!\n")
	// If we blow this, we're in space
	tree_stack := [128]uint{}
	stack_len := 0
	pad_buf := [?]u8{0..<64 = '\t',}

	tree_stack[0] = head; stack_len += 1
	for stack_len > 0 {
		stack_len -= 1

		tree_idx := tree_stack[stack_len]
		cur_node := tree[tree_idx]

		//padding := pad_buf[len(pad_buf) - stack_len:]
		fmt.printf("%d | %v\n", tree_idx, cur_node)

		if cur_node.child_count == 0 {
			continue
		}

		for i := (cur_node.child_count - 1); i >= 0; i -= 1 {
			tree_stack[stack_len] = cur_node.children[i]; stack_len += 1
		}
	}
	fmt.printf("ded!\n")
}

chunk_events :: proc() {
	for proc_v in &processes {
		for tm in &proc_v.threads {
			for depth, d_idx in &tm.depths {
				depth.head = build_tree(&tm, d_idx, depth.events)
			}
		}
	}
}

calc_selftime :: proc(ev: ^Event, threads: ^[dynamic]Thread, thread_idx, depth_idx: int) -> f64 {
	thread := threads[thread_idx]
	depth := thread.depths[depth_idx]
	tree := depth.tree

	tree_stack := [128]uint{}
	stack_len := 0

	start_time := ev.timestamp - total_min_time
	end_time := ev.timestamp + bound_duration(ev^, thread.max_time) - total_min_time

	child_time := 0.0
	tree_stack[0] = depth.head; stack_len += 1
	for stack_len > 0 {
		stack_len -= 1

		tree_idx := tree_stack[stack_len]
		cur_node := tree[tree_idx]

		if end_time < cur_node.start_time || start_time > cur_node.end_time {
			continue
		}

		if cur_node.start_time >= start_time && cur_node.end_time <= end_time {
			child_time += cur_node.weight
			continue
		}

		if cur_node.child_count == 0 {
			scan_arr := depth.events[cur_node.start_idx:cur_node.start_idx+uint(cur_node.arr_len)]
			weight := 0.0
			scan_loop: for ev in scan_arr {

				ev_start_time := ev.timestamp - total_min_time
				if ev_start_time < start_time {
					continue
				}

				ev_end_time := ev.timestamp + bound_duration(ev, thread.max_time) - total_min_time
				if ev_end_time > end_time {
					break scan_loop
				}

				weight += bound_duration(ev, thread.max_time)
			}
			child_time += weight
			continue
		}

		for i := cur_node.child_count - 1; i >= 0; i -= 1 {
			tree_stack[stack_len] = cur_node.children[i]; stack_len += 1
		}
	}

	self_time := bound_duration(ev^, thread.max_time) - child_time
	return self_time
}

generate_selftimes :: proc() {
	for proc_v, p_idx in &processes {
		for tm, t_idx in &proc_v.threads {

			// skip the bottom rank, it's already set up correctly
			if len(tm.depths) == 1 {
				continue
			}

			for depth, d_idx in &tm.depths {
				// skip the last depth
				if d_idx == (len(tm.depths) - 1) {
					continue
				}

				for ev, e_idx in &depth.events {
					self_time := calc_selftime(&ev, &proc_v.threads, t_idx, d_idx+1)
					ev.self_time = self_time
				}
			}
		}
	}
}

instant_count := 0
first_chunk: bool
init_loading_state :: proc(size: u32, name: string) {
	b := strings.builder_from_slice(file_name_store[:])
	strings.write_string(&b, name)
	file_name = strings.to_string(b)

	// reset selection state
	clicked_on_rect = false
	did_multiselect = false
	stats_state = .NoStats
	total_tracked_time = 0.0
	selected_event = EventID{-1, -1, -1, -1}

	// wipe all allocators
	free_all(scratch_allocator)
	free_all(small_global_allocator)
	free_all(big_global_allocator)
	free_all(temp_allocator)
	processes = make([dynamic]Process, small_global_allocator)
	process_map = vh_init(scratch_allocator)
	global_instants = make([dynamic]Instant, big_global_allocator)
	string_block = make([dynamic]u8, big_global_allocator)
	total_max_time = 0
	total_min_time = 0x7fefffffffffffff

	first_chunk = true
	event_count = 0

	jp = JSONParser{}
	bp = Parser{}
	
	loading_config = true
	post_loading = false

	fmt.printf("Loading a %.1f MB config\n", f64(size) / 1024 / 1024)
	start_bench("parse config")
}

is_json := false
finish_loading :: proc () {
	stop_bench("parse config")
	fmt.printf("Got %d events, %d instants\n", event_count, instant_count)

	free_all(temp_allocator)
	free_all(scratch_allocator)

	start_bench("process events")
	if is_json {
		json_process_events()
	} else {
		bin_process_events()
	}
	stop_bench("process events")

	free_all(temp_allocator)
	free_all(scratch_allocator)

	generate_color_choices()

	start_bench("chunk events")
	chunk_events()
	stop_bench("chunk events")

	start_bench("generate event stats")
	generate_selftimes()
	stop_bench("generate event stats")

	t = 0
	frame_count = 0

	free_all(temp_allocator)
	free_all(scratch_allocator)
	queue.init(&fps_history, 0, small_global_allocator)

	loading_config = false
	post_loading = true
	return
}

stamp_scale: f64
@export
load_config_chunk :: proc "contextless" (start, total_size: u32, chunk: []u8) {
	context = wasmContext
	defer free_all(context.temp_allocator)

	if first_chunk {
		header_sz := size_of(spall.Header)
		if len(chunk) < header_sz {
			fmt.printf("Uh, you passed me an empty file?\n")
			finish_loading()
			return
		}
		magic := (^u64)(raw_data(chunk))^

		is_json = magic != spall.MAGIC
		if is_json {
			stamp_scale = 1
			jp = init_json_parser(total_size)
		} else {
			hdr := cast(^spall.Header)raw_data(chunk)
			if hdr.version != 0 {
				return
			}

			stamp_scale = hdr.timestamp_unit
			bp = init_parser(total_size)
			bp.pos += i64(header_sz)
		}

		first_chunk = false
	}

	if is_json {
		load_json_chunk(&jp, start, total_size, chunk)
	} else {
		load_binary_chunk(&bp, start, total_size, chunk)
	}

	return
}

bound_duration :: proc(ev: Event, max_ts: f64) -> f64 {
	return ev.duration == -1 ? (max_ts - ev.timestamp) : ev.duration
}

/*
default_config := `[
	{"cat":"function", "name":"0", "ph":"X", "pid":0, "tid": 0, "ts": 0, "dur": 1},
	{"cat":"function", "name":"1", "ph":"X", "pid":0, "tid": 0, "ts": 1, "dur": 1},
	{"cat":"function", "name":"2", "ph":"X", "pid":0, "tid": 0, "ts": 3, "dur": 1},
	{"cat":"function", "name":"3", "ph":"X", "pid":0, "tid": 0, "ts": 4, "dur": 1},
	{"cat":"function", "name":"4", "ph":"X", "pid":0, "tid": 0, "ts": 6, "dur": 1},
	{"cat":"function", "name":"5", "ph":"X", "pid":0, "tid": 1, "ts": 1, "dur": 1},
]`
*/

/*
default_config := `[
	{"cat":"function", "name":"0", "ph":"B", "pid":0, "tid": 0, "ts": 0},
	{"cat":"function",             "ph":"E", "pid":0, "tid": 0, "ts": 1},
	{"cat":"function", "name":"1", "ph":"B", "pid":0, "tid": 0, "ts": 1},
	{"cat":"function", "name":"2", "ph":"B", "pid":0, "tid": 0, "ts": 2},
	{"cat":"function",             "ph":"E", "pid":0, "tid": 0, "ts": 4},
]`
*/

/*
default_config := `[
	{"name":"call", "ph":"X", "pid":0, "tid": 0, "ts":    0, "dur": 9000},

	{"name":"foo",  "ph":"X", "pid":0, "tid": 0, "ts": 1000, "dur": 3000},
	{"name":"A", "ph":"X", "pid":0, "tid": 0, "ts": 1000, "dur": 1000},
	{"name":"A", "ph":"X", "pid":0, "tid": 0, "ts": 3000, "dur": 1000},

	{"name":"foo",  "ph":"X", "pid":0, "tid": 0, "ts": 5000, "dur": 3000},
	{"name":"A", "ph":"X", "pid":0, "tid": 0, "ts": 5000, "dur": 1000},
	{"name":"A", "ph":"X", "pid":0, "tid": 0, "ts": 7000, "dur": 1000},
]`
*/

default_config_name :: "../demos/example_config.json"
default_config := string(#load(default_config_name))
