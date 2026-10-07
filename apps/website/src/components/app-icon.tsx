import { useId, type SVGProps } from "react"

/** The rounded square the icon is drawn in. */
const frame =
  "M697 1H201C90.5431 1 1 90.5431 1 201V697C1 807.457 90.5431 897 201 897H697C807.457 897 897 807.457 897 697V201C897 90.5431 807.457 1 697 1Z"

/**
 * The Immount app icon, drawn inline. As an `<img>`, Safari rasterizes the SVG's filters at 1x,
 * so the folders blur on high-density screens. IDs are scoped per instance so the filters and
 * gradients resolve when the icon appears more than once on a page.
 */
export function AppIcon(props: SVGProps<SVGSVGElement>) {
  const id = useId()

  return (
    <svg viewBox="0 0 898 898" fill="none" {...props}>
      <path d={frame} fill={`url(#${id}-background)`} stroke="#45536B" strokeWidth="2" />
      {/* Glass rim: a soft light band inside the edge, lit from the top left and bottom right. */}
      <g clipPath={`url(#${id}-rim-clip)`} filter={`url(#${id}-rim-blur)`}>
        <path d={frame} stroke={`url(#${id}-rim-light)`} strokeWidth="28" />
      </g>
      <g filter={`url(#${id}-red-shadow)`}>
        <path d="M313.173 191.742C310.389 171.937 318.9 160.643 338.705 157.859L410.005 147.839C420.568 146.354 430.46 149.677 439.681 157.806L461.697 177.938L565.675 163.324C585.48 160.541 596.775 169.052 599.558 188.857L625.305 372.057C628.274 393.183 619.196 405.23 598.07 408.199L380.211 438.817C359.085 441.786 347.038 432.708 344.069 411.582L313.173 191.742Z" fill="#D71C21" />
        <path d="M318.943 204.059C316.623 187.555 324.046 178.096 341.211 175.684L412.51 165.664" stroke="#FF695A" strokeOpacity="0.5" strokeWidth="4" />
        <path d="M306.808 254.236C302.23 236.03 309.843 225.535 329.649 222.751L583.157 187.123C602.963 184.339 612.983 193.366 613.219 214.203L614.551 374.578C614.787 395.415 605.002 407.225 585.197 410.008L385.163 438.121C366.017 440.812 354.109 432.724 349.438 413.857L306.808 254.236Z" fill={`url(#${id}-red-fill)`} stroke="#FF695A" strokeOpacity="0.3" strokeWidth="2" />
        <path d="M339.519 235.502L583.125 201.265L339.519 235.502Z" fill="black" />
        <path d="M339.519 235.502L583.125 201.265" stroke="white" strokeOpacity="0.32" strokeWidth="4" strokeLinecap="round" />
      </g>
      <g filter={`url(#${id}-amber-shadow)`}>
        <path d="M656.456 259.768C674.432 251.001 687.804 255.605 696.571 273.581L728.134 338.294C732.81 347.881 732.707 358.315 727.825 369.597L715.482 396.757L761.511 491.13C770.279 509.106 765.674 522.478 747.698 531.245L581.422 612.344C562.247 621.696 547.984 616.785 538.632 597.61L442.191 399.876C432.839 380.701 437.75 366.438 456.924 357.086L656.456 259.768Z" fill="#E89500" />
        <path d="M646.526 269.062C661.505 261.756 672.795 265.892 680.393 281.471L711.956 346.184" stroke="#FFD356" strokeOpacity="0.5" strokeWidth="4" />
        <path d="M595.054 273.027C610.955 263.046 623.289 267.044 632.057 285.02L744.28 515.111C753.047 533.087 747.559 545.406 727.815 552.069L575.701 602.895C555.957 609.558 541.701 603.902 532.933 585.926L444.382 404.37C435.907 386.993 439.92 373.168 456.42 362.895L595.054 273.027Z" fill={`url(#${id}-amber-fill)`} stroke="#FFD356" strokeOpacity="0.3" strokeWidth="2" />
        <path d="M622.98 298.347L730.82 519.451L622.98 298.347Z" fill="black" />
        <path d="M622.98 298.347L730.82 519.451" stroke="white" strokeOpacity="0.32" strokeWidth="4" strokeLinecap="round" />
      </g>
      <g filter={`url(#${id}-green-shadow)`}>
        <path d="M697.841 607.271C711.734 621.658 711.487 635.798 697.1 649.691L645.308 699.707C637.635 707.116 627.679 710.243 615.441 709.086L585.797 705.74L510.266 778.679C495.879 792.572 481.739 792.325 467.846 777.939L339.334 644.861C324.515 629.515 324.778 614.432 340.124 599.613L498.379 446.788C513.725 431.969 528.807 432.232 543.627 447.578L697.841 607.271Z" fill="#00A950" />
        <path d="M685.933 600.698C697.511 612.687 697.065 624.702 684.597 636.743L632.804 686.758" stroke="#54DD7D" strokeOpacity="0.5" strokeWidth="4" />
        <path d="M666.257 552.972C680.663 565.01 680.672 577.976 666.285 591.869L482.134 769.701C467.747 783.595 454.335 782.182 441.897 765.463L346.552 636.5C334.114 619.781 335.089 604.475 349.476 590.582L494.782 450.261C508.689 436.831 523.077 436.375 537.946 448.893L666.257 552.972Z" fill={`url(#${id}-green-fill)`} stroke="#54DD7D" strokeOpacity="0.3" strokeWidth="2" />
        <path d="M650.805 587.355L473.848 758.241L650.805 587.355Z" fill="black" />
        <path d="M650.805 587.355L473.848 758.241" stroke="white" strokeOpacity="0.32" strokeWidth="4" strokeLinecap="round" />
      </g>
      <g filter={`url(#${id}-blue-shadow)`}>
        <path d="M380.134 754.015C370.745 771.674 357.22 775.808 339.561 766.419L275.989 732.617C266.571 727.609 260.521 719.107 257.839 707.11L251.861 677.883L159.152 628.588C141.493 619.199 137.358 605.675 146.747 588.016L233.6 424.67C243.615 405.834 258.041 401.424 276.877 411.439L471.126 514.723C489.962 524.738 494.372 539.164 484.357 558L380.134 754.015Z" fill="#1660DB" />
        <path d="M382.705 740.658C374.881 755.374 363.316 758.663 348.012 750.526L284.44 716.724" stroke="#67B0FF" strokeOpacity="0.5" strokeWidth="4" />
        <path d="M422.016 707.197C415.019 724.617 402.69 728.633 385.031 719.244L158.997 599.059C141.338 589.669 138.537 576.477 150.594 559.481L243.782 428.952C255.839 411.956 270.696 408.153 288.355 417.542L466.711 512.375C483.781 521.452 488.661 534.995 481.35 553.004L422.016 707.197Z" fill={`url(#${id}-blue-fill)`} stroke="#67B0FF" strokeOpacity="0.3" strokeWidth="2" />
        <path d="M384.54 703.127L167.335 587.637L384.54 703.127Z" fill="black" />
        <path d="M384.54 703.127L167.335 587.637" stroke="white" strokeOpacity="0.32" strokeWidth="4" strokeLinecap="round" />
      </g>
      <g filter={`url(#${id}-pink-shadow)`}>
        <path d="M142.396 497.204C122.7 493.731 114.588 482.146 118.061 462.45L130.564 391.544C132.416 381.039 138.633 372.658 149.213 366.4L175.163 351.683L193.396 248.278C196.869 228.582 208.454 220.47 228.15 223.943L410.339 256.068C431.349 259.773 440.001 272.13 436.297 293.139L398.094 509.797C394.389 530.806 382.033 539.458 361.023 535.754L142.396 497.204Z" fill="#D8519B" />
        <path d="M155.893 495.522C139.48 492.628 132.778 482.646 135.788 465.576L148.29 394.67" stroke="#FFA7D4" strokeOpacity="0.5" strokeWidth="4" />
        <path d="M199.865 522.568C181.134 521.297 173.506 510.813 176.978 491.116L221.432 239.006C224.905 219.31 236.587 212.569 256.476 218.784L409.414 267.075C429.304 273.29 437.512 286.245 434.039 305.941L398.962 504.873C395.605 523.912 384.233 532.738 364.846 531.351L199.865 522.568Z" fill={`url(#${id}-pink-fill)`} stroke="#FFA7D4" strokeOpacity="0.3" strokeWidth="2" />
        <path d="M192.155 485.669L234.872 243.406L192.155 485.669Z" fill="black" />
        <path d="M192.155 485.669L234.872 243.406" stroke="white" strokeOpacity="0.32" strokeWidth="4" strokeLinecap="round" />
      </g>
      <defs>
        <filter id={`${id}-red-shadow`} x="290.519" y="141.495" width="349.335" height="320.13" filterUnits="userSpaceOnUse" colorInterpolationFilters="sRGB">
          <feFlood floodOpacity="0" result="BackgroundImageFix" />
          <feColorMatrix in="SourceAlpha" type="matrix" values="0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 127 0" result="hardAlpha" />
          <feOffset dy="8" />
          <feGaussianBlur stdDeviation="7" />
          <feColorMatrix type="matrix" values="0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0.18 0" />
          <feBlend mode="normal" in2="BackgroundImageFix" result="effect1_dropShadow_14_2" />
          <feBlend mode="normal" in="SourceGraphic" in2="effect1_dropShadow_14_2" result="shape" />
        </filter>
        <filter id={`${id}-amber-shadow`} x="423.592" y="249.457" width="356.231" height="389.486" filterUnits="userSpaceOnUse" colorInterpolationFilters="sRGB">
          <feFlood floodOpacity="0" result="BackgroundImageFix" />
          <feColorMatrix in="SourceAlpha" type="matrix" values="0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 127 0" result="hardAlpha" />
          <feOffset dy="8" />
          <feGaussianBlur stdDeviation="7" />
          <feColorMatrix type="matrix" values="0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0.18 0" />
          <feBlend mode="normal" in2="BackgroundImageFix" result="effect1_dropShadow_14_2" />
          <feBlend mode="normal" in="SourceGraphic" in2="effect1_dropShadow_14_2" result="shape" />
        </filter>
        <filter id={`${id}-green-shadow`} x="314.414" y="429.867" width="407.665" height="381.05" filterUnits="userSpaceOnUse" colorInterpolationFilters="sRGB">
          <feFlood floodOpacity="0" result="BackgroundImageFix" />
          <feColorMatrix in="SourceAlpha" type="matrix" values="0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 127 0" result="hardAlpha" />
          <feOffset dy="8" />
          <feGaussianBlur stdDeviation="7" />
          <feColorMatrix type="matrix" values="0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0.18 0" />
          <feBlend mode="normal" in2="BackgroundImageFix" result="effect1_dropShadow_14_2" />
          <feBlend mode="normal" in="SourceGraphic" in2="effect1_dropShadow_14_2" result="shape" />
        </filter>
        <filter id={`${id}-blue-shadow`} x="127.858" y="400.224" width="375.713" height="393.084" filterUnits="userSpaceOnUse" colorInterpolationFilters="sRGB">
          <feFlood floodOpacity="0" result="BackgroundImageFix" />
          <feColorMatrix in="SourceAlpha" type="matrix" values="0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 127 0" result="hardAlpha" />
          <feOffset dy="8" />
          <feGaussianBlur stdDeviation="7" />
          <feColorMatrix type="matrix" values="0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0.18 0" />
          <feBlend mode="normal" in2="BackgroundImageFix" result="effect1_dropShadow_14_2" />
          <feBlend mode="normal" in="SourceGraphic" in2="effect1_dropShadow_14_2" result="shape" />
        </filter>
        <filter id={`${id}-pink-shadow`} x="103.28" y="209.548" width="347.849" height="349.039" filterUnits="userSpaceOnUse" colorInterpolationFilters="sRGB">
          <feFlood floodOpacity="0" result="BackgroundImageFix" />
          <feColorMatrix in="SourceAlpha" type="matrix" values="0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 127 0" result="hardAlpha" />
          <feOffset dy="8" />
          <feGaussianBlur stdDeviation="7" />
          <feColorMatrix type="matrix" values="0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0.18 0" />
          <feBlend mode="normal" in2="BackgroundImageFix" result="effect1_dropShadow_14_2" />
          <feBlend mode="normal" in="SourceGraphic" in2="effect1_dropShadow_14_2" result="shape" />
        </filter>
        <linearGradient id={`${id}-background`} x1="1" y1="1" x2="897" y2="897" gradientUnits="userSpaceOnUse">
          <stop stopColor="#233045" />
          <stop offset="0.6" stopColor="#131B2C" />
          <stop offset="1" stopColor="#0B1020" />
        </linearGradient>
        <linearGradient id={`${id}-red-fill`} x1="302.641" y1="226.547" x2="495.209" y2="475.543" gradientUnits="userSpaceOnUse">
          <stop stopColor="#FF695A" />
          <stop offset="0.52" stopColor="#FA2921" />
          <stop offset="1" stopColor="#D71C21" />
        </linearGradient>
        <linearGradient id={`${id}-amber-fill`} x1="620.101" y1="260.507" x2="442.798" y2="520.594" gradientUnits="userSpaceOnUse">
          <stop stopColor="#FFD356" />
          <stop offset="0.52" stopColor="#FFB400" />
          <stop offset="1" stopColor="#E89500" />
        </linearGradient>
        <linearGradient id={`${id}-green-fill`} x1="685.904" y1="572.924" x2="383.757" y2="484.67" gradientUnits="userSpaceOnUse">
          <stop stopColor="#54DD7D" />
          <stop offset="0.52" stopColor="#18C249" />
          <stop offset="1" stopColor="#00A950" />
        </linearGradient>
        <linearGradient id={`${id}-blue-fill`} x1="409.112" y1="732.047" x2="399.677" y2="417.417" gradientUnits="userSpaceOnUse">
          <stop stopColor="#67B0FF" />
          <stop offset="0.52" stopColor="#1E83F7" />
          <stop offset="1" stopColor="#1660DB" />
        </linearGradient>
        <linearGradient id={`${id}-pink-fill`} x1="172.243" y1="517.975" x2="468.559" y2="411.776" gradientUnits="userSpaceOnUse">
          <stop stopColor="#FFA7D4" />
          <stop offset="0.52" stopColor="#ED79B5" />
          <stop offset="1" stopColor="#D8519B" />
        </linearGradient>
        <clipPath id={`${id}-rim-clip`}>
          <path d={frame} />
        </clipPath>
        <filter id={`${id}-rim-blur`} x="-5%" y="-5%" width="110%" height="110%">
          <feGaussianBlur stdDeviation="4" />
        </filter>
        <linearGradient id={`${id}-rim-light`} x1="1" y1="1" x2="897" y2="897" gradientUnits="userSpaceOnUse">
          <stop stopColor="white" stopOpacity="0.3" />
          <stop offset="0.3" stopColor="white" stopOpacity="0.05" />
          <stop offset="0.7" stopColor="white" stopOpacity="0.04" />
          <stop offset="1" stopColor="white" stopOpacity="0.24" />
        </linearGradient>
      </defs>
    </svg>
  )
}
