import { Request, Response } from "express";

const router = require('express').Router();

router.post('/', (req: Request, res: Response) => {
    // Handle scan creation
    res.status(201).json({ message: 'Scan created' });
});

router.get('/:id', (req: Request, res: Response) => {
    // Handle fetching a specific scan by ID
    res.json({ id: req.params.id, status: 'completed' });
});

router.get('/', (req: Request, res: Response) => {
    // Handle fetching all scans
    res.json([{ id: '1', status: 'completed' }, { id: '2', status: 'pending' }]);
});

module.exports = router;