import { HttpClient, HttpHeaders } from '@angular/common/http';
import { Injectable } from '@angular/core';
import { Observable, last } from 'rxjs';
import { User } from '../models/User';
import { environment } from '../../environments/environment';

@Injectable({
  providedIn: 'root'
})
export class UserService {

  baseURL:string=environment.apiUrl + "/user"
  constructor(private  httpClient:HttpClient) { }

  getAllUsers():Observable<any>{
    let headers = new HttpHeaders();
    headers.append("Access-Control-Allow-Origin", "*")
    return this.httpClient.get(this.baseURL + "/all",{headers})
  }

  deleteUser(id:string):Observable<any>{
    let headers = new HttpHeaders();
    headers.append("Access-Control-Allow-Origin", "*")
    return this.httpClient.delete(this.baseURL + "/delete/"+id,{headers})
  }

  addUser(firstname:string,lastname:string):Observable<any>{
    let body = { firstName: firstname, lastName: lastname };
    let url=this.baseURL + "/add";
    let headers = new HttpHeaders();
    headers.append("Access-Control-Allow-Origin", "*")
    return this.httpClient.post(url,body,{headers})
  }
}
