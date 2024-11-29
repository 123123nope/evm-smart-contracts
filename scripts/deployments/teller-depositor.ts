import { task } from 'hardhat/config';
import { DEFAULT_PROXY_FACTORY } from '../helpers/constants';
import { create3 } from '../helpers/create3Deployment';

task('deploy-teller-depositor', 'Deploys the TellerWithMultiAssetSupportDepositor contract')
    .addParam('ledgerNetwork', 'The network name of ledger', 'mainnet')
    .addParam('admin', 'The owner of the proxy')
    .addParam(
        'proxyFactoryAddr',
        'The ProxyFactory address',
        DEFAULT_PROXY_FACTORY
    )
    .setAction(async (taskArgs, hre, network) => {
        const { ethers } = hre;

        const {
            ledgerNetwork,
            proxyFactoryAddr,
            admin,
        } = taskArgs;

        await create3(
            'TellerWithMultiAssetSupportDepositor',
            [admin],
            proxyFactoryAddr,
            ledgerNetwork,
            admin,
            hre
        );
    });
