// Packed component conversion on the GPU, for copies between guest memory and a host texture (nvn_mtl.m packed16_gpu).
// Kind 4 reverses RGBA4's nibbles; kinds 10 and 11 preserve the RGB5 family's red / blue exchange.
#include <metal_stdlib>
using namespace metal;
struct P { device const uchar *s; device uchar *d; uint w, h, row, img, drow, dimg, shift; };
kernel void rb_swap(constant P &p [[buffer(0)]], uint3 g [[thread_position_in_grid]]) {
  if (g.x >= p.w || g.y >= p.h) return;
  ushort v = ((device const ushort *)(p.s + g.z * p.img + g.y * p.row))[g.x], m = ushort(31u | 31u << p.shift);
  ((device ushort *)(p.d + g.z * p.dimg + g.y * p.drow))[g.x] = p.shift == 4 ? ushort((v & 0x000fu) << 12 | (v & 0x00f0u) << 4 | (v & 0x0f00u) >> 4 | (v & 0xf000u) >> 12)
    : ushort((v & ~m) | (v & 31u) << p.shift | (v >> p.shift & 31u)); }
