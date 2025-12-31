require('dotenv').config();

module.exports = {
  networks: {
    shasta: {
      privateKey: process.env.PRIVATE_KEY_SHASTA,
      userFeePercentage: 50,
      feeLimit: 5000 * 1e6,  // Increased for large contract deployments
      fullHost: 'https://api.shasta.trongrid.io',
      network_id: '2'
    },
    mainnet: {
      privateKey: process.env.PRIVATE_KEY_MAINNET,
      userFeePercentage: 30,
      feeLimit: 1000 * 1e6,
      fullHost: 'https://api.trongrid.io',
      network_id: '1'
    }
  },
  compilers: {
    solc: {
      version: '0.8.24',
      docker: false,
      settings: {
        optimizer: {
          enabled: true,
          runs: 200
        },
        viaIR: false
      }
    },    
  },
  ignore: [
    "contracts/openzeppelin/**/*.sol"
  ]
};
