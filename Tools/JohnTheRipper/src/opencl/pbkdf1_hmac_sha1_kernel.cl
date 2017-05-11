/*
 * This software is Copyright (c) 2014 magnum,
 * and it is hereby released to the general public under the following terms:
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted.
 *
 * increased salt_len from 52, to 115.  salts [56-115] bytes
 * require 2 sha1 limbs to handle.  Salts [0-55] bytes in length are handled by
 * 1 sha1 limb.  (Feb. 28/16, JimF)
 *
 * This is pbkdf1 but using hmac-sha1 (NetBSD crypt)
 *
 * Build-time (at run-time for host code) defines:
 * -DHASH_LOOPS is number of rounds (of 2 x SHA1) per call to loop kernel.
 *
 * For a fixed iterations count, define ITERATIONS. Otherwise salt->iterations
 * will be used (slower).
 *
 * For a fixed output length, define OUTLEN. Otherwise salt->outlen will be
 * used.
 *
 * Example for 4096 iterations and output length 20:
 * -DITERATIONS=4095
 * -DHASH_LOOPS=105 (made by factors of 4095)
 * -DOUTLEN=20
 * pbkdf1_init()
 * for (ITERATIONS / HASH_LOOPS)
 *     pbkdf1_loop()
 * pbkdf1_final()
 *
 *
 * Example for variable iterations count and length:
 * -DHASH_LOOPS=100
 * pbkdf1_init()
 * for ((salt.iterations - 1) / HASH_LOOPS)
 *     pbkdf1_loop()
 * pbkdf1_final() // first 20 bytes of output
 * for ((salt.iterations - 1) / HASH_LOOPS)
 *     pbkdf1_loop()
 * pbkdf1_final() // next 20 bytes of output
 * ...
 */

#include "opencl_device_info.h"
#include "opencl_misc.h"
#include "opencl_sha1.h"

#ifdef ITERATIONS
#if ITERATIONS % HASH_LOOPS
#error HASH_LOOPS must be a divisor of ITERATIONS
#endif
#endif

#define CONCAT(TYPE,WIDTH)	TYPE ## WIDTH
#define VECTOR(x, y)		CONCAT(x, y)

/* MAYBE_VECTOR_UINT need to be defined before this header */
#include "opencl_pbkdf1_hmac_sha1.h"

inline void hmac_sha1(__global MAYBE_VECTOR_UINT *state,
                      __global MAYBE_VECTOR_UINT *ipad,
                      __global MAYBE_VECTOR_UINT *opad,
                      MAYBE_CONSTANT uchar *salt, uint saltlen)
{
	uint i;
	MAYBE_VECTOR_UINT W[16];
	MAYBE_VECTOR_UINT output[5];

	for (i = 0; i < 5; i++)
		output[i] = ipad[i];

	for (i = 0; i < 15; i++)
		W[i] = 0;

	if (saltlen < 56) {
		for (i = 0; i < saltlen; i++)
			PUTCHAR_BE(W, i, salt[i]);
		PUTCHAR_BE(W, saltlen, 0x80);
		W[15] = (64 + saltlen) << 3;
		sha1_block(MAYBE_VECTOR_UINT, W, output);
	} else {
		// handles 2 limbs of salt and loop-count (up to 115 byte salt)
		uint j;
		W[15] = 0;	// first buffer will NOT get length, so zero it out also.
		for (i = 0; i < saltlen && i < 64; i++)
			PUTCHAR_BE(W, i, salt[i]);
		if (saltlen < 64)
			PUTCHAR_BE(W, saltlen, 0x80);
		sha1_block(MAYBE_VECTOR_UINT, W, output);

		// build and process 2nd limb
		for (j = 0; j < 15; j++)
			W[j] = 0;
		for (; i < saltlen; i++)
			PUTCHAR_BE(W, i - 64, salt[i]);
		if (saltlen >= 64)
			PUTCHAR_BE(W, saltlen-64, 0x80);
		W[15] = (64 + saltlen) << 3;
		sha1_block(MAYBE_VECTOR_UINT, W, output);
	}
	for (i = 0; i < 5; i++)
		W[i] = output[i];
	W[5] = 0x80000000;
	W[15] = (64 + 20) << 3;

	for (i = 0; i < 5; i++)
		output[i] = opad[i];
	sha1_block_160Z(MAYBE_VECTOR_UINT, W, output);

	for (i = 0; i < 5; i++)
		state[i] = output[i];
}

inline void preproc(__global const MAYBE_VECTOR_UINT *key,
                    __global MAYBE_VECTOR_UINT *state, uint padding)
{
	uint i;
	MAYBE_VECTOR_UINT W[16];
	MAYBE_VECTOR_UINT output[5];

	for (i = 0; i < 16; i++)
		W[i] = key[i] ^ padding;

	sha1_single(MAYBE_VECTOR_UINT, W, output);

	for (i = 0; i < 5; i++)
		state[i] = output[i];
}

__kernel
__attribute__((vec_type_hint(MAYBE_VECTOR_UINT)))
void pbkdf1_init(__global const MAYBE_VECTOR_UINT *inbuffer,
                 MAYBE_CONSTANT pbkdf1_salt *salt,
                 __global pbkdf1_state *state)
{
	uint gid = get_global_id(0);
	uint i;

	preproc(&inbuffer[gid * 16], state[gid].ipad, 0x36363636);
	preproc(&inbuffer[gid * 16], state[gid].opad, 0x5c5c5c5c);

	hmac_sha1(state[gid].out, state[gid].ipad, state[gid].opad,
	          salt->salt, salt->length);

	for (i = 0; i < 5; i++)
		state[gid].W[i] = state[gid].out[i];

#ifndef ITERATIONS
	state[gid].iter_cnt = salt->iterations - 1;
#endif
	state[gid].pass = 0;
}

__kernel
__attribute__((vec_type_hint(MAYBE_VECTOR_UINT)))
void pbkdf1_loop(__global pbkdf1_state *state)
{
	uint gid = get_global_id(0);
	uint i, j;
	MAYBE_VECTOR_UINT W[16];
	MAYBE_VECTOR_UINT ipad[5];
	MAYBE_VECTOR_UINT opad[5];
	MAYBE_VECTOR_UINT output[5];
#if defined ITERATIONS
#define iterations HASH_LOOPS
#else
	uint iterations = state[gid].iter_cnt > HASH_LOOPS ?
		HASH_LOOPS : state[gid].iter_cnt;
#endif
	for (i = 0; i < 5; i++)
		W[i] = state[gid].W[i];
	for (i = 0; i < 5; i++)
		ipad[i] = state[gid].ipad[i];
	for (i = 0; i < 5; i++)
		opad[i] = state[gid].opad[i];

	for (j = 0; j < iterations; j++) {
		for (i = 0; i < 5; i++)
			output[i] = ipad[i];
		W[5] = 0x80000000;
		W[15] = (64 + 20) << 3;
		sha1_block_160Z(MAYBE_VECTOR_UINT, W, output);

		for (i = 0; i < 5; i++)
			W[i] = output[i];
		W[5] = 0x80000000;
		W[15] = (64 + 20) << 3;
		for (i = 0; i < 5; i++)
			output[i] = opad[i];
		sha1_block_160Z(MAYBE_VECTOR_UINT, W, output);

		for (i = 0; i < 5; i++)
			W[i] = output[i];
	}

	for (i = 0; i < 5; i++)
		state[gid].W[i] = W[i];
	for (i = 0; i < 5; i++)
		state[gid].out[i] = W[i];

#ifndef ITERATIONS
	state[gid].iter_cnt -= iterations;
#endif
}

#ifndef OUTLEN
#define OUTLEN salt->outlen
#endif

__kernel
__attribute__((vec_type_hint(MAYBE_VECTOR_UINT)))
void pbkdf1_final(MAYBE_CONSTANT pbkdf1_salt *salt,
                  __global pbkdf1_out *out,
                  __global pbkdf1_state *state)
{
	uint gid = get_global_id(0);
	uint i, base;

	base = state[gid].pass++ * 5;

	// First/next 20 bytes of output
	for (i = 0; i < 5; i++)
#ifdef SCALAR
		out[gid].dk[base + i] = SWAP32(state[gid].out[i]);
#else

#define VEC_OUT(NUM)	  \
	out[gid * V_WIDTH + 0x##NUM].dk[base + i] = \
		SWAP32(state[gid].out[i].s##NUM)

	{
		VEC_OUT(0);
		VEC_OUT(1);
#if V_WIDTH > 2
		VEC_OUT(2);
#if V_WIDTH > 3
		VEC_OUT(3);
#if V_WIDTH > 4
		VEC_OUT(4);
		VEC_OUT(5);
		VEC_OUT(6);
		VEC_OUT(7);
#if V_WIDTH > 8
		VEC_OUT(8);
		VEC_OUT(9);
		VEC_OUT(a);
		VEC_OUT(b);
		VEC_OUT(c);
		VEC_OUT(d);
		VEC_OUT(e);
		VEC_OUT(f);
#endif
#endif
#endif
#endif
	}
#endif

	/* Was this the last pass? If not, prepare for next one */
	if (4 * base + 20 < OUTLEN) {
		hmac_sha1(state[gid].out, state[gid].ipad, state[gid].opad,
		          salt->salt, salt->length);

		for (i = 0; i < 5; i++)
			state[gid].W[i] = state[gid].out[i];

#ifndef ITERATIONS
		state[gid].iter_cnt = salt->iterations - 1;
#endif
	}
}
