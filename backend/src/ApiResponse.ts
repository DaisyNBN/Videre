type ApiResponseType = {
    success: boolean;
    message: string;
    data?: any;
}

class ApiResponse implements ApiResponseType {
    success: boolean;
    message: string;
    data?: any;

    constructor(success: boolean, message: string, data?: any) {
        this.success = success;
        this.message = message;
        if (data) {
            this.data = data;
        }
    }
}

export { ApiResponse, ApiResponseType };