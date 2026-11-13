-- V1, core equivalence: the unmodified Galaga core (library ref, 18.432 MHz
-- clock_18, ROM entities from make_ref_proms.py, the changes of ref_patch.py)
-- and the TangCore port of it (library work, 48 MHz clock with enables, ROMs
-- loaded from the image build_rom.py makes from our MRA) run side by side with
-- the same scripted inputs. Every pixel (r, g, b, hs, vs, csync, blankn at each
-- pixel enable) and the audio output at every pixel enable (the sound machine
-- updates it once per pixel) must be identical, from the first pixel after
-- reset is released (before that the port's ROMs are still being loaded; the
-- reference has them built in).
--
-- clock_18 of the reference rises on the clock_48 edges where the port has
-- ce18 and falls on those where it has ce18n (the testbench runs a copy of the
-- port's enable generator).
--
-- normal_test: an instance of the port with pause = 0, compared in lock-step.
-- pause_test: an instance of the port with its pause input set at random
-- (lengths 1 to 6000 clock_48 cycles); its output stream, taken at its own
-- pixel enables, must be identical too.
--
-- Generics: rom_file (image from build_rom.py), out_dir, n_frames,
-- normal_test, pause_test, dump, dsw_a and dsw_b (the port's DIP switches; the
-- reference gets the same values from ref_patch.py), players and the script
-- frames (below). With dump (and normal_test), the port's stream is written to
-- <out_dir>/stream.bin (2 bytes per pixel enable from frame 0; see frames.py)
-- and the audio to <out_dir>/audio.bin (one 16-bit little-endian sample of
-- audio(9:0) per 128 pixel enables, 48 kHz). Every 50 frames a progress line
-- gives the counts so far. The result is printed and written to
-- <out_dir>/v1_result.txt.
--
-- Frames: frame 0 starts at the first pixel enable where the video counters
-- are at hcnt 192, vcnt 0 (the start of line 0); a frame is 384 x 264 pixel
-- enables.
--
-- Scripted inputs, by frame, applied to each instance right after the first
-- pixel of the frame, on its own timeline (on the falling clock_48 edge, so
-- the reference and the port see them at the same clock edge):
--  players = 1: coin at frame c_coin, 1P start at c_start, then from c_play a
--    repeating pattern of right, left and fire presses.
--  players = 2: coin at c_coin and c_coin + 20, 2P start at c_start, then no
--    input (for the cocktail run: player 1 is lost, then it is player 2's
--    turn).
--
-- Also counted (normal_test): the port's CPU memory reads (opcode fetches
-- included), those at 0x6800-0x6807 (the DIP switches) and at 0x6808-0x6FFF, and the frames where the game
-- turns the screen (flip_h, 0xA007) on or off.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.textio.all;

library ref;

entity tb_v1 is
	generic (
		rom_file    : string  := "galaga.rom";
		out_dir     : string  := ".";
		n_frames    : integer := 800;
		normal_test : boolean := true;
		pause_test  : boolean := true;
		dump        : boolean := true;
		dsw_a       : integer := 16#F7#;
		dsw_b       : integer := 16#97#;
		players     : integer := 1;
		c_coin      : integer := 400;
		c_start     : integer := 460;
		c_play      : integer := 520
	);
end tb_v1;

architecture sim of tb_v1 is

	constant FRAME    : integer := 384 * 264;
	constant ROM_SIZE : integer := 16#9820#;
	constant RING_N   : integer := 2**21;

	signal clk48    : std_logic := '0';
	signal clock_18 : std_logic := '0';
	signal tb_acc   : unsigned(6 downto 0) := (others => '0'); -- as the port's ce_acc
	signal tb_ce18  : std_logic := '0';
	signal tb_ce18n : std_logic := '0';
	signal done     : std_logic := '0';
	signal reset    : std_logic := '1';

	signal dn_addr  : std_logic_vector(15 downto 0) := (others => '0');
	signal dn_data  : std_logic_vector(7 downto 0) := (others => '0');
	signal dn_wr    : std_logic := '0';

	-- inputs: 0 coin, 1 start1, 2 start2, 3 left1, 4 right1, 5 fire1,
	-- 6 left2, 7 right2, 8 fire2
	signal in_ref, in_cv, in_cp : std_logic_vector(8 downto 0) := (others => '0');
	signal pause_cp : std_logic := '0';

	constant dip_a : std_logic_vector(7 downto 0) := std_logic_vector(to_unsigned(dsw_a, 8));
	constant dip_b : std_logic_vector(7 downto 0) := std_logic_vector(to_unsigned(dsw_b, 8));

	type outs_t is record
		ce : std_logic;
		r, g : std_logic_vector(2 downto 0);
		b : std_logic_vector(1 downto 0);
		hs, vs, cs, bn : std_logic;
		audio : std_logic_vector(9 downto 0);
	end record;
	signal o_ref, o_cv, o_cp : outs_t;

	-- from the normal port's monitor (g_cv)
	signal cv_flip : std_logic := '0';
	type int3 is array(1 to 3) of integer;
	signal n_rd, n_dsw, n_hi : int3 := (0, 0, 0);

	-- bits 21..10 video (hs vs csync blankn r g b), 9..0 audio
	function pack(o : outs_t) return std_logic_vector is
	begin
		return o.hs & o.vs & o.cs & o.bn & o.r & o.g & o.b & o.audio;
	end function;

	function script(f : integer) return std_logic_vector is
		variable v : std_logic_vector(8 downto 0) := (others => '0');
		variable t : integer;
	begin
		if f < 0 then return v; end if;
		if f >= c_coin and f < c_coin + 6 then v(0) := '1'; end if;
		if players = 2 and f >= c_coin + 20 and f < c_coin + 26 then v(0) := '1'; end if;
		if f >= c_start and f < c_start + 6 then
			if players = 2 then v(2) := '1'; else v(1) := '1'; end if;
		end if;
		if players = 1 and f >= c_play then
			t := (f - c_play) mod 240;
			if    t < 50  then v(4) := '1'; v(7) := '1'; -- right
			elsif t >= 90 and t < 190 then v(3) := '1'; v(6) := '1'; -- left
			elsif t >= 210 then v(4) := '1'; v(7) := '1'; -- right
			end if;
			if (f - c_play) mod 16 >= 8 and (f - c_play) mod 16 < 11 then
				v(5) := '1'; v(8) := '1';                    -- fire
			end if;
		end if;
		return v;
	end function;

	-- bits as characters (keeps U and X visible)
	function hex(v : std_logic_vector) return string is
		variable str : string(1 to v'length);
		variable k : integer := 1;
		variable im : string(1 to 3);
	begin
		for i in v'range loop
			im := std_logic'image(v(i));
			str(k) := im(2);
			k := k + 1;
		end loop;
		return str;
	end function;

	function b01(s : std_logic) return integer is
	begin
		if s = '1' or s = 'H' then return 1; else return 0; end if;
	end function;

	function u01(v : std_logic_vector) return integer is
		variable n : integer := 0;
	begin
		for i in v'range loop n := n * 2 + b01(v(i)); end loop;
		return n;
	end function;

	function hex16(n : integer) return string is
		constant d : string(1 to 16) := "0123456789ABCDEF";
	begin
		return d(n / 4096 mod 16 + 1) & d(n / 256 mod 16 + 1) & d(n / 16 mod 16 + 1) & d(n mod 16 + 1);
	end function;

begin

	-- 48 MHz (period 20 ns in simulation time)
	process
	begin
		while done = '0' loop
			clk48 <= '1'; wait for 10 ns;
			clk48 <= '0'; wait for 10 ns;
		end loop;
		wait;
	end process;

	-- the port's enable generator (pause = 0), and the reference's clock_18:
	-- rising on the edges where the port has ce18, falling where it has ce18n
	process (clk48)
	begin
		if rising_edge(clk48) then
			tb_ce18n <= tb_ce18;
			tb_ce18  <= '0';
			if tb_acc >= 125-48 then
				tb_acc <= tb_acc - (125-48);
				tb_ce18 <= '1';
			else
				tb_acc <= tb_acc + 48;
			end if;
			if tb_ce18 = '1' then
				clock_18 <= '1';
			elsif tb_ce18n = '1' then
				clock_18 <= '0';
			end if;
		end if;
	end process;

	u_ref : entity ref.galaga
	port map (
		clock_18 => clock_18, reset => reset,
		video_r => o_ref.r, video_g => o_ref.g, video_b => o_ref.b, video_clk => open,
		video_csync => o_ref.cs, video_blankn => o_ref.bn, video_hs => o_ref.hs, video_vs => o_ref.vs,
		audio => o_ref.audio,
		b_test => '0', b_svce => '0', coin => in_ref(0), start1 => in_ref(1), start2 => in_ref(2),
		left1 => in_ref(3), right1 => in_ref(4), fire1 => in_ref(5),
		left2 => in_ref(6), right2 => in_ref(7), fire2 => in_ref(8)
	);
	o_ref.ce <= '0'; -- the reference's pixel enable is its ena_vidgen (in main)

	g_cv : if normal_test generate
		u_cv : entity work.galaga
		port map (
			clock_48 => clk48, reset => reset, pause => '0',
			dn_addr => dn_addr, dn_data => dn_data, dn_wr => dn_wr,
			video_ce => o_cv.ce, video_r => o_cv.r, video_g => o_cv.g, video_b => o_cv.b,
			video_csync => o_cv.cs, video_blankn => o_cv.bn, video_hs => o_cv.hs, video_vs => o_cv.vs,
			audio => o_cv.audio, dip_switch_a => dip_a, dip_switch_b => dip_b,
			b_test => '0', b_svce => '0', coin => in_cv(0), start1 => in_cv(1), start2 => in_cv(2),
			left1 => in_cv(3), right1 => in_cv(4), fire1 => in_cv(5),
			left2 => in_cv(6), right2 => in_cv(7), fire2 => in_cv(8)
		);
	end generate;

	g_no_cv : if not normal_test generate
		o_cv.ce <= '0';
	end generate;

	-- (a generate of its own: GHDL resolves external names into g_cv only
	-- once g_cv is elaborated)
	g_mon : if normal_test generate
		-- the port's CPU memory reads (a read starts when RD_n falls with
		-- MREQ_n low; both change only on ce18) and flip_h
		mon : block
			alias flip  is <<signal .tb_v1.g_cv.u_cv.flip_h : std_logic>>;
			alias ce18  is <<signal .tb_v1.g_cv.u_cv.ce18 : std_logic>>;
			alias a1    is <<signal .tb_v1.g_cv.u_cv.cpu1_addr : std_logic_vector(15 downto 0)>>;
			alias a2    is <<signal .tb_v1.g_cv.u_cv.cpu2_addr : std_logic_vector(15 downto 0)>>;
			alias a3    is <<signal .tb_v1.g_cv.u_cv.cpu3_addr : std_logic_vector(15 downto 0)>>;
			alias mreq1 is <<signal .tb_v1.g_cv.u_cv.cpu1_mreq_n : std_logic>>;
			alias mreq2 is <<signal .tb_v1.g_cv.u_cv.cpu2_mreq_n : std_logic>>;
			alias mreq3 is <<signal .tb_v1.g_cv.u_cv.cpu3_mreq_n : std_logic>>;
			alias rd1   is <<signal .tb_v1.g_cv.u_cv.cpu1.RD_n : std_logic>>;
			alias rd2   is <<signal .tb_v1.g_cv.u_cv.cpu2.RD_n : std_logic>>;
			alias rd3   is <<signal .tb_v1.g_cv.u_cv.cpu3.RD_n : std_logic>>;
		begin
			cv_flip <= flip;

			process (clk48)
				variable rd_prev : std_logic_vector(1 to 3) := "111";
				variable rd_now, mreq : std_logic_vector(1 to 3);
				variable a : integer;
				variable shown : integer := 0;
				variable l : line;
			begin
				if rising_edge(clk48) and ce18 = '1' then
					rd_now := rd1 & rd2 & rd3;
					mreq := mreq1 & mreq2 & mreq3;
					for k in 1 to 3 loop
						if rd_now(k) = '0' and rd_prev(k) = '1' and mreq(k) = '0' then
							n_rd(k) <= n_rd(k) + 1;
							case k is
								when 1 => a := to_integer(unsigned(a1));
								when 2 => a := to_integer(unsigned(a2));
								when others => a := to_integer(unsigned(a3));
							end case;
							if a >= 16#6800# and a <= 16#6807# then
								n_dsw(k) <= n_dsw(k) + 1;
							elsif a >= 16#6808# and a <= 16#6FFF# then
								n_hi(k) <= n_hi(k) + 1;
								if shown < 20 then
									shown := shown + 1;
									write(l, "CPU " & integer'image(k) & " reads 0x" & hex16(a) & " at " & time'image(now));
									writeline(output, l);
								end if;
							end if;
						end if;
					end loop;
					rd_prev := rd_now;
				end if;
			end process;
		end block;
	end generate;

	g_cp : if pause_test generate
		u_cp : entity work.galaga
		port map (
			clock_48 => clk48, reset => reset, pause => pause_cp,
			dn_addr => dn_addr, dn_data => dn_data, dn_wr => dn_wr,
			video_ce => o_cp.ce, video_r => o_cp.r, video_g => o_cp.g, video_b => o_cp.b,
			video_csync => o_cp.cs, video_blankn => o_cp.bn, video_hs => o_cp.hs, video_vs => o_cp.vs,
			audio => o_cp.audio, dip_switch_a => dip_a, dip_switch_b => dip_b,
			b_test => '0', b_svce => '0', coin => in_cp(0), start1 => in_cp(1), start2 => in_cp(2),
			left1 => in_cp(3), right1 => in_cp(4), fire1 => in_cp(5),
			left2 => in_cp(6), right2 => in_cp(7), fire2 => in_cp(8)
		);
	end generate;

	g_no_cp : if not pause_test generate
		o_cp.ce <= '0';
	end generate;

	-- ROM download under reset, one byte per clock_48 cycle (changed on the
	-- falling edge), then reset released on a falling edge
	load : process
		type char_file is file of character;
		file rom_f : char_file;
		variable c : character;
	begin
		file_open(rom_f, rom_file, read_mode);
		for i in 0 to ROM_SIZE - 1 loop
			read(rom_f, c);
			wait until falling_edge(clk48);
			dn_addr <= std_logic_vector(to_unsigned(i, 16));
			dn_data <= std_logic_vector(to_unsigned(character'pos(c), 8));
			dn_wr <= '1';
		end loop;
		file_close(rom_f);
		wait until falling_edge(clk48);
		dn_wr <= '0';
		for i in 0 to 999 loop
			wait until falling_edge(clk48);
		end loop;
		reset <= '0';
		wait;
	end process;

	main : process
		alias ref_ena  is <<signal .tb_v1.u_ref.ena_vidgen : std_logic>>;
		alias ref_hcnt is <<signal .tb_v1.u_ref.hcnt : std_logic_vector(8 downto 0)>>;
		alias ref_vcnt is <<signal .tb_v1.u_ref.vcnt : std_logic_vector(8 downto 0)>>;

		type char_file is file of character;
		file str_f : char_file;
		file aud_f : char_file;
		file res_f : text;
		type ring_t is array(0 to RING_N-1) of std_logic_vector(21 downto 0);
		variable ring : ring_t;
		variable n_ref, n_cv, n_cp : integer := 0;
		variable n_start : integer := -1;          -- first pixel after reset
		variable n0 : integer := -1;               -- first pixel of frame 0
		variable n_end : integer := integer'high;
		variable mm_cv_v, mm_cv_a, mm_cp_v, mm_cp_a : integer := 0;
		variable shown : integer := 0;
		variable s : std_logic_vector(21 downto 0);
		variable pend_ref, pend_cv, pend_cp : boolean := false;
		variable pv_ref, pv_cv, pv_cp : std_logic_vector(8 downto 0);
		variable seed1, seed2 : positive := 12345;
		variable rnd : real;
		variable pause_cnt, gap_cnt : integer := 0;
		variable n_pauses, n_pause_cycles : integer := 0;
		variable max_lag : integer := 0;
		variable n_meta, first_meta, last_meta : integer := 0;
		variable l : line;
		variable pause_next : std_logic := '0';
		variable flip_prev : std_logic := '0';
		variable a : integer;

		-- frame of pixel n (negative before frame 0)
		impure function frame_of(n : integer) return integer is
		begin
			if n0 < 0 or n < n0 then return -1; end if;
			return (n - n0) / FRAME;
		end function;

		-- first pixel of a frame: the inputs for that frame are due
		impure function frame_start(n : integer) return boolean is
		begin
			return n0 >= 0 and n >= n0 and (n - n0) mod FRAME = 0;
		end function;

		procedure check(name : string; p : integer; s : std_logic_vector(21 downto 0);
		                variable mm_v, mm_a : inout integer) is
			variable r : std_logic_vector(21 downto 0);
			variable ll : line;
		begin
			if n_start < 0 or p < n_start then return; end if;
			r := ring(p mod RING_N);
			if s(21 downto 10) /= r(21 downto 10) then mm_v := mm_v + 1; end if;
			if s(9 downto 0) /= r(9 downto 0) then mm_a := mm_a + 1; end if;
			if s /= r and shown < 20 then
				shown := shown + 1;
				write(ll, name & " mismatch at pixel " & integer'image(p) &
					" (frame " & integer'image(frame_of(p)) & ", line " & integer'image(((p - n0) mod FRAME) / 384) &
					", pixel " & integer'image((p - n0) mod 384) & "): ref " & hex(r) & " port " & hex(s) &
					" (hs vs csync blankn r g b audio)");
				writeline(output, ll);
			end if;
		end procedure;

		procedure progress(variable ll : inout line) is
		begin
			write(ll, "frame " & integer'image(frame_of(n_ref)) & " at " & time'image(now) &
				": video/audio mismatches port " & integer'image(mm_cv_v) & "/" & integer'image(mm_cv_a) &
				", paused port " & integer'image(mm_cp_v) & "/" & integer'image(mm_cp_a) &
				", undefined outputs " & integer'image(n_meta) &
				", pauses " & integer'image(n_pauses) & ", max lag " & integer'image(max_lag) &
				", reads 0x6808-0x6FFF " & integer'image(n_hi(1) + n_hi(2) + n_hi(3)));
		end procedure;

		procedure wbyte(file f : char_file; v : integer) is
		begin
			write(f, character'val(v mod 256));
		end procedure;
	begin
		if dump and normal_test then
			file_open(str_f, out_dir & "/stream.bin", write_mode);
			file_open(aud_f, out_dir & "/audio.bin", write_mode);
		end if;

		loop
			wait until rising_edge(clk48);

			-- reference: pixel at the rising edge of clock_18 with ena_vidgen
			if tb_ce18 = '1' and ref_ena = '1' then
				if n_start < 0 and reset = '0' then
					n_start := n_ref;
				end if;
				if n0 < 0 and ref_hcnt = "011000000" and ref_vcnt = "000000000" then
					n0 := n_ref;
					n_end := n0 + n_frames * FRAME;
					write(l, "frame 0 starts at pixel " & integer'image(n0) & " (" & time'image(now) & ")");
					writeline(output, l);
				end if;
				ring(n_ref mod RING_N) := pack(o_ref);
				if frame_start(n_ref) then
					pv_ref := script(frame_of(n_ref)); pend_ref := true;
					if frame_of(n_ref) mod 50 = 0 then
						progress(l);
						writeline(output, l);
					end if;
				end if;
				n_ref := n_ref + 1;
			end if;

			-- port, lock-step
			if o_cv.ce = '1' then
				assert tb_ce18 = '1' report "port pixel enable off ce18" severity failure;
				s := pack(o_cv);
				if n_cv < n_end then
					assert n_cv = n_ref - 1 report "port out of step with the reference" severity failure;
					check("port", n_cv, s, mm_cv_v, mm_cv_a);
					-- outputs not 0 or 1 (an undefined value in the simulation)
					if n_start >= 0 and n_cv >= n_start and is_x(s) then
						if n_meta = 0 then
							first_meta := n_cv;
							write(l, "first undefined output at pixel " & integer'image(n_cv) & ": " & hex(s) &
								" (hs vs csync blankn r g b audio)");
							writeline(output, l);
						end if;
						n_meta := n_meta + 1;
						last_meta := n_cv;
					end if;
					if dump and n0 >= 0 and n_cv >= n0 then
						wbyte(str_f, u01(s(17 downto 10)));
						wbyte(str_f, b01(s(18)) + b01(s(21)) * 2 + b01(s(20)) * 4 +
						             b01(s(19)) * 8 + b01(cv_flip) * 16);
						if (n_cv - n0) mod 128 = 0 then
							a := u01(s(9 downto 0));
							wbyte(aud_f, a mod 256);
							wbyte(aud_f, a / 256);
						end if;
					end if;
				end if;
				if frame_start(n_cv) then
					pv_cv := script(frame_of(n_cv)); pend_cv := true;
					if cv_flip /= flip_prev then
						write(l, "flip_h " & std_logic'image(cv_flip) & " at frame " & integer'image(frame_of(n_cv)));
						writeline(output, l);
						flip_prev := cv_flip;
					end if;
				end if;
				n_cv := n_cv + 1;
			end if;

			-- port with pauses
			if pause_test then
				if o_cp.ce = '1' then
					if n_cp < n_end then
						assert n_cp < n_ref report "paused port ahead of reference" severity failure;
						assert n_ref - n_cp < RING_N report "paused port too far behind" severity failure;
						check("paused port", n_cp, pack(o_cp), mm_cp_v, mm_cp_a);
					end if;
					if frame_start(n_cp) then
						pv_cp := script(frame_of(n_cp)); pend_cp := true;
					end if;
					n_cp := n_cp + 1;
				end if;
				if n_ref - n_cp > max_lag then max_lag := n_ref - n_cp; end if;

				-- random pauses while the reference runs, from reset release
				-- on (reset is released at the same clock edge for all, so
				-- each instance must be at the same point then)
				if pause_cnt > 0 then
					pause_cnt := pause_cnt - 1;
					n_pause_cycles := n_pause_cycles + 1;
					if pause_cnt = 0 then pause_next := '0'; end if;
				elsif gap_cnt > 0 then
					gap_cnt := gap_cnt - 1;
				elsif n_ref < n_end and n_start >= 0 then
					uniform(seed1, seed2, rnd);
					if rnd < 0.5 then
						uniform(seed1, seed2, rnd);
						pause_cnt := 1 + integer(trunc(rnd * 16.0));
					else
						uniform(seed1, seed2, rnd);
						pause_cnt := 17 + integer(trunc(rnd * 6000.0));
					end if;
					uniform(seed1, seed2, rnd);
					gap_cnt := 1 + integer(trunc(rnd * 400000.0));
					if rnd < 0.1 then gap_cnt := 1 + integer(trunc(rnd * 100.0)); end if;
					n_pauses := n_pauses + 1;
					pause_next := '1';
				end if;
			end if;

			exit when (not normal_test or n_cv >= n_end) and (not pause_test or n_cp >= n_end);

			-- inputs and pause change on the falling edge, where no instance
			-- samples anything
			if pend_ref or pend_cv or pend_cp or pause_next /= pause_cp then
				wait until falling_edge(clk48);
				if pend_ref then in_ref <= pv_ref; pend_ref := false; end if;
				if pend_cv then in_cv <= pv_cv; pend_cv := false; end if;
				if pend_cp then in_cp <= pv_cp; pend_cp := false; end if;
				pause_cp <= pause_next;
			end if;
		end loop;

		if dump and normal_test then
			file_close(str_f);
			file_close(aud_f);
		end if;

		file_open(res_f, out_dir & "/v1_result.txt", write_mode);
		for k in 0 to 1 loop
			write(l, string'("V1 result"));
			if k = 0 then writeline(output, l); else writeline(res_f, l); end if;
			write(l, "frames: " & integer'image(n_frames) & " (" & integer'image(FRAME) &
				" pixel enables each) from pixel " & integer'image(n0) &
				"; compared from pixel " & integer'image(n_start) & " (reset released) to " & integer'image(n_end) &
				"; DSWA " & hex16(dsw_a) & ", DSWB " & hex16(dsw_b) & ", players " & integer'image(players));
			if k = 0 then writeline(output, l); else writeline(res_f, l); end if;
			if normal_test then
				write(l, "port: pixels compared " & integer'image(n_end - n_start) &
					", video mismatches " & integer'image(mm_cv_v) &
					", audio samples compared " & integer'image(n_end - n_start) &
					", audio mismatches " & integer'image(mm_cv_a));
				if k = 0 then writeline(output, l); else writeline(res_f, l); end if;
				write(l, "port: outputs with undefined bits (U, X) after reset: " & integer'image(n_meta) &
					" (first at pixel " & integer'image(first_meta) & "; last at pixel " & integer'image(last_meta) & ")");
				if k = 0 then writeline(output, l); else writeline(res_f, l); end if;
				write(l, "CPU memory reads (CPU 1, 2, 3): " & integer'image(n_rd(1)) & ", " &
					integer'image(n_rd(2)) & ", " & integer'image(n_rd(3)) &
					"; at 0x6800-0x6807: " & integer'image(n_dsw(1)) & ", " &
					integer'image(n_dsw(2)) & ", " & integer'image(n_dsw(3)) &
					"; reads 0x6808-0x6FFF: " & integer'image(n_hi(1)) & ", " &
					integer'image(n_hi(2)) & ", " & integer'image(n_hi(3)));
				if k = 0 then writeline(output, l); else writeline(res_f, l); end if;
			end if;
			if pause_test then
				write(l, "paused port: pixels compared " & integer'image(n_end - n_start) &
					", video mismatches " & integer'image(mm_cp_v) &
					", audio mismatches " & integer'image(mm_cp_a) &
					", pauses " & integer'image(n_pauses) &
					", paused clock_48 cycles " & integer'image(n_pause_cycles) &
					", max lag " & integer'image(max_lag) & " pixels");
				if k = 0 then writeline(output, l); else writeline(res_f, l); end if;
			end if;
			if mm_cv_v + mm_cv_a + mm_cp_v + mm_cp_a = 0 then
				write(l, string'("PASS"));
			else
				write(l, string'("FAIL"));
			end if;
			if k = 0 then writeline(output, l); else writeline(res_f, l); end if;
		end loop;
		file_close(res_f);

		done <= '1';
		wait;
	end process;

end sim;
