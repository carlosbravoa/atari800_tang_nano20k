#!/usr/bin/env python3
"""Draw a measurement sheet for calibrating the Tang Nano 20K case."""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle, FancyArrowPatch

BLU="#1f4e9c"; GLD="#c98f00"; RED="#c0392b"; GRY="#555"; BLK="#101010"
Lx, Wy = 54.04, 22.55

def dim(ax, p0, p1, lab, color=RED, lab_off=(0,0), fs=14):
    ax.add_patch(FancyArrowPatch(p0, p1, arrowstyle="<->",
                 mutation_scale=12, color=color, lw=1.6))
    mx, my = (p0[0]+p1[0])/2+lab_off[0], (p0[1]+p1[1])/2+lab_off[1]
    ax.text(mx, my, lab, color=color, fontsize=fs, fontweight="bold",
            ha="center", va="center",
            bbox=dict(fc="white", ec=color, boxstyle="circle,pad=0.18"))

fig = plt.figure(figsize=(13.5, 13))
fig.suptitle("Tang Nano 20K — measurement sheet for the case",
             fontsize=18, fontweight="bold", y=0.985)
fig.text(0.5, 0.945, "board is 54.04 x 22.55 x 1.6 mm — mark every value you can; "
         "calipers ideal, a ruler is fine. If something is centered, just say so.",
         ha="center", fontsize=11, style="italic")

# ============================================================= TOP VIEW
axt = fig.add_axes([0.05, 0.60, 0.90, 0.32]); axt.set_aspect("equal")
axt.set_title("TOP view (component side up)   —   USB-C end LEFT,  HDMI end RIGHT",
              fontsize=13, fontweight="bold")
axt.add_patch(Rectangle((0,0), Lx, Wy, fc=BLK, ec="k"))
for yy in (1.4, Wy-1.4):
    for x in [2+i*1.9 for i in range(27)]:
        axt.add_patch(plt.Circle((x, yy), 0.45, fc=GLD, ec="none"))
axt.add_patch(Rectangle((2.0,1.0),3,3,fc="silver",ec="k")); axt.text(3.5,2.5,"S1",fontsize=9,ha="center",va="center")
axt.add_patch(Rectangle((2.0,Wy-4.0),3,3,fc="silver",ec="k")); axt.text(3.5,Wy-2.5,"S2",fontsize=9,ha="center",va="center")
for x in [7+i*1.6 for i in range(6)]:
    axt.add_patch(Rectangle((x,1.0),1.0,1.6,fc=RED,ec="none"))
axt.text(11.5,3.7,"LEDs",color=RED,fontsize=10,ha="center")
axt.add_patch(Rectangle((Lx-1.0,Wy/2-7.5),1.6,15,fc="#888",ec="k"))
axt.text(Lx-3.2,Wy/2,"HDMI",fontsize=10,ha="center",va="center",rotation=90)
axt.add_patch(Rectangle((-0.6,Wy/2-4),1.0,8,fc="#888",ec="k"))
axt.text(2.2,Wy/2+6.6,"USB-C",fontsize=9,ha="center")
axt.add_patch(Rectangle((6,6),15,11,fc="none",ec=BLU,ls="--",lw=1.5))
axt.text(13.5,11.5,"microSD\n(UNDERSIDE)",color=BLU,fontsize=9,ha="center",va="center")
# dimension letters
dim(axt,(0,-2.6),(3.5,-2.6),"B")                       # USB-C end -> buttons
dim(axt,(-3.0,0),(-3.0,1.4),"A",color=GLD)             # long edge -> pad row
dim(axt,(Lx+2.4,0),(Lx+2.4,1.0),"C",color=BLK)         # button center -> long edge
dim(axt,(7,-2.6),(15.6,-2.6),"D",color=RED)            # LED x-range
dim(axt,(Lx+6.5,2.0),(Lx+6.5,0),"E",color=RED)         # LED -> edge (drawn at right margin)
dim(axt,(Lx+2.4,Wy/2-7.5),(Lx+2.4,Wy/2+7.5),"F",color=GRY)
dim(axt,(-0.1,Wy+2.2),(0.9,Wy+2.2),"G",color=GRY)
axt.set_xlim(-13, Lx+12); axt.set_ylim(-6, Wy+5); axt.axis("off")

# ============================================================= SIDE VIEW
axs = fig.add_axes([0.05, 0.30, 0.55, 0.24]); axs.set_aspect("equal")
axs.set_title("SIDE view (long axis) — heights above / below the PCB",
              fontsize=12, fontweight="bold")
t=1.6
axs.add_patch(Rectangle((0,0),Lx,t,fc=GLD,ec="k")); axs.text(Lx/2,t/2,"PCB 1.6",ha="center",va="center",fontsize=8)
axs.add_patch(Rectangle((Lx-9,t),9,6.0,fc="#888",ec="k")); axs.text(Lx-4.5,t+3,"HDMI",ha="center",va="center",fontsize=9)
axs.add_patch(Rectangle((0,t),8,3.2,fc="#888",ec="k")); axs.text(4,t+1.6,"USB-C",ha="center",va="center",fontsize=8)
axs.add_patch(Rectangle((2,t),3,1.4,fc="silver",ec="k"))
axs.add_patch(Rectangle((22,t),1.2,8.0,fc=GLD,ec="k"))
axs.text(24,t+7.5,"pins +\njumpers",fontsize=8,va="center")
axs.add_patch(Rectangle((4,-1.8),15,1.8,fc="none",ec=BLU,ls="--",lw=1.5)); axs.text(11.5,-0.9,"microSD",color=BLU,fontsize=8,ha="center",va="center")
dim(axs,(Lx+2,t),(Lx+2,t+6.0),"J",color=RED)
dim(axs,(-2,t),(-2,t+3.2),"K",color=GRY)
dim(axs,(20.5,t),(20.5,t+8.0),"L",color=BLK)
dim(axs,(-2,-1.8),(-2,0),"M",color=BLU)
axs.text(Lx/2,-3.8,"USB-C END  <---- length ---->  HDMI END",ha="center",fontsize=9,color=GRY)
axs.set_xlim(-12, Lx+12); axs.set_ylim(-5, t+11); axs.axis("off")

# ============================================================= LEGEND
axl = fig.add_axes([0.62, 0.04, 0.36, 0.50]); axl.axis("off")
rows = [
 ("A", GLD, "long edge -> nearest pin-pad row", "clip_ov (clips grab bare edge)"),
 ("B", RED, "USB-C end -> S1/S2 centers (x)", "btn1_x / btn2_x"),
 ("C", BLK, "each button center -> its long edge", "btn1_y / btn2_y"),
 ("D", RED, "LED row start & end from USB-C (x)", "led_win_x / _len"),
 ("E", RED, "LED row -> long edge (y)", "led_win_y / _wid"),
 ("F", GRY, "HDMI width + is it centered?", "hdmi_w / hdmi_y_off"),
 ("G", GRY, "USB-C width + center", "usbc_w / usbc_y_off"),
 ("J", RED, "HDMI height above PCB top  ***", "standoff (case clears it)"),
 ("K", GRY, "USB-C height above PCB top", "(sanity check)"),
 ("L", BLK, "pin + tallest jumper stack height", "headroom"),
 ("M", BLU, "microSD drop below PCB bottom", "(clearance check)"),
]
axl.text(0.0, 1.0, "What to measure", fontsize=13, fontweight="bold", transform=axl.transAxes)
y=0.94
for k,c,what,param in rows:
    axl.text(0.0, y, k, color="white", fontsize=11, fontweight="bold",
             ha="center", va="center", transform=axl.transAxes,
             bbox=dict(fc=c, ec="k", boxstyle="circle,pad=0.22"))
    axl.text(0.07, y+0.012, what, fontsize=10.5, va="center", transform=axl.transAxes)
    axl.text(0.07, y-0.028, "-> "+param, fontsize=8.5, color=GRY, style="italic",
             va="center", transform=axl.transAxes)
    y-=0.085
axl.text(0.0, y+0.01, "*** most important: J and A", fontsize=10,
         fontweight="bold", color=RED, transform=axl.transAxes)

fig.savefig("img/measure_sheet.png", dpi=135)
print("saved img/measure_sheet.png")
